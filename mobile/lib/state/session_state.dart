import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/audio_api.dart';
import '../api/midi_api.dart';
import '../api/sync_api.dart';
import '../models/sung_point.dart';
import '../models/target_point.dart';
import '../models/track_candidate.dart';

enum LoadStatus { idle, loading, ok, error }

enum ReferenceSource { midi, recording }

/// Spiegelt das `state`-Objekt aus frontend/app.js als ChangeNotifier, damit die
/// Widgets denselben Ablauf (MIDI-Upload -> Spurwahl -> Aufnahme -> Kurven) fahren.
class SessionState extends ChangeNotifier {
  final MidiApi midiApi;
  final AudioApi audioApi;
  final SyncApi syncApi;

  SessionState({required this.midiApi, required this.audioApi, required this.syncApi});

  String? midiSessionId;
  List<TrackCandidate> candidates = [];
  int? selectedTrackIndex;
  int transposeSemitones = 0;
  int referenceTransposeSemitones = 0;
  List<TargetPoint> targetCurve = [];
  List<SungPoint> sungCurve = [];

  LoadStatus midiStatus = LoadStatus.idle;
  String midiMessage = '';
  LoadStatus audioStatus = LoadStatus.idle;
  String audioMessage = '';

  ReferenceSource referenceSource = ReferenceSource.midi;
  List<SungPoint> referenceRawCurve = [];
  LoadStatus referenceStatus = LoadStatus.idle;
  String referenceMessage = '';
  Uint8List? referenceAudioBytes;
  Uint8List? sungAudioBytes;

  List<SungPoint> alignedSungCurve = [];
  LoadStatus alignStatus = LoadStatus.idle;
  String alignMessage = '';

  /// Die fuer den Chart zu zeichnende gesungene Kurve: ausgerichtet, sobald ein
  /// Alignment vorliegt, sonst (noch nicht fertig oder fehlgeschlagen) die rohe
  /// Kurve - kein Absturz/leerer Chart bei einem Alignment-Fehler.
  List<SungPoint> get displayedSungCurve =>
      alignedSungCurve.isNotEmpty ? alignedSungCurve : sungCurve;

  bool get audioSectionEnabled => referenceSource == ReferenceSource.midi
      ? selectedTrackIndex != null
      : referenceRawCurve.isNotEmpty;

  /// Der fuer die aktuelle Quelle jeweils relevante Transpose-Wert, an den die
  /// UI (TransposeControl) gebunden werden soll, damit der angezeigte Regler-
  /// Wert nie vom tatsaechlich gerenderten Kurvenzustand abweicht.
  int get displayedTranspose => referenceSource == ReferenceSource.midi
      ? transposeSemitones
      : referenceTransposeSemitones;

  List<TargetPoint> get displayedTargetCurve {
    if (referenceSource == ReferenceSource.midi) return targetCurve;
    return referenceRawCurve
        .map((p) => TargetPoint(
              t: p.t,
              hz: p.hz == null
                  ? null
                  : p.hz! * math.pow(2, referenceTransposeSemitones / 12),
              midiNote: null,
            ))
        .toList();
  }

  Future<void> uploadMidi(Uint8List bytes, String filename) async {
    midiStatus = LoadStatus.loading;
    midiMessage = 'Lade und analysiere MIDI-Datei…';
    candidates = [];
    _resetAudioSection();
    notifyListeners();

    try {
      final result = await midiApi.uploadMidi(bytes, filename);
      midiSessionId = result.sessionId;
      candidates = result.candidates;
      if (!result.hasPlausibleVocalTrack) {
        midiStatus = LoadStatus.error;
        midiMessage = 'Warnung: Diese MIDI-Datei enthält wahrscheinlich keine eigene '
            'Gesangsmelodie. Bitte prüfe die Spuren unten sorgfältig oder besorge eine '
            'passendere Datei.';
      } else {
        midiStatus = LoadStatus.ok;
        midiMessage = '${result.candidates.length} Spur(en) gefunden. Bitte eine auswählen.';
      }
    } catch (e) {
      midiStatus = LoadStatus.error;
      midiMessage = 'Fehler: ${_messageOf(e)}';
    }
    notifyListeners();
  }

  Future<void> selectTrack(int index) async {
    selectedTrackIndex = index;
    transposeSemitones = 0;
    midiStatus = LoadStatus.loading;
    midiMessage = 'Lade Zielmelodie der gewählten Spur…';
    notifyListeners();
    await _reloadTargetCurve();
  }

  Future<void> setTranspose(int semitones) async {
    if (referenceSource == ReferenceSource.recording) {
      referenceTransposeSemitones = semitones;
      notifyListeners();
      return;
    }
    if (selectedTrackIndex == null) return;
    transposeSemitones = semitones;
    await _reloadTargetCurve();
  }

  Future<void> _reloadTargetCurve() async {
    if (midiSessionId == null || selectedTrackIndex == null) return;
    try {
      targetCurve = await midiApi.getTrackCurve(
        midiSessionId!,
        selectedTrackIndex!,
        transpose: transposeSemitones,
      );
      midiStatus = LoadStatus.ok;
      midiMessage = 'Spur ausgewählt. Jetzt eine Gesangsaufnahme aufnehmen oder hochladen.';
    } catch (e) {
      midiStatus = LoadStatus.error;
      midiMessage = 'Fehler: ${_messageOf(e)}';
    }
    notifyListeners();
  }

  Future<void> analyzeAudio(Uint8List bytes, String filename) async {
    sungAudioBytes = bytes;
    audioStatus = LoadStatus.loading;
    audioMessage = 'Analysiere Tonhöhe der Aufnahme…';
    alignedSungCurve = [];
    alignStatus = LoadStatus.idle;
    alignMessage = '';
    notifyListeners();
    try {
      sungCurve = await audioApi.analyzeAudio(bytes, filename);
      audioStatus = LoadStatus.ok;
      audioMessage = 'Analyse fertig.';
      notifyListeners();
      await align();
      return;
    } catch (e) {
      audioStatus = LoadStatus.error;
      audioMessage = 'Fehler: ${_messageOf(e)}';
    }
    notifyListeners();
  }

  /// Richtet die gesungene Kurve per DTW auf die Zielmelodie aus (MIDI oder
  /// Referenzaufnahme, je nach referenceSource). Wird automatisch am Ende einer
  /// erfolgreichen analyzeAudio() angestossen - kein manueller Button. Transpose-
  /// Aenderungen loesen bewusst KEIN erneutes Alignment aus: onset_envelope_from_
  /// midi_track (backend/sync/features.py) haengt nicht von transpose ab, das
  /// Warping-Ergebnis bleibt bei einer reinen Tonhoehenverschiebung gueltig.
  Future<void> align() async {
    if (sungAudioBytes == null) return;
    alignStatus = LoadStatus.loading;
    alignMessage = 'Richte Aufnahme zeitlich aus…';
    notifyListeners();
    try {
      if (referenceSource == ReferenceSource.midi) {
        if (midiSessionId == null || selectedTrackIndex == null) {
          throw StateError('Keine MIDI-Spur ausgewählt.');
        }
        alignedSungCurve = await syncApi.alignWithMidi(
          sungAudioBytes!,
          'gesang.wav',
          sessionId: midiSessionId!,
          trackIndex: selectedTrackIndex!,
          transpose: transposeSemitones,
        );
      } else {
        if (referenceAudioBytes == null) {
          throw StateError('Keine Referenzaufnahme vorhanden.');
        }
        alignedSungCurve = await syncApi.alignWithReference(
          sungAudioBytes!,
          'gesang.wav',
          referenceAudioBytes!,
          'referenz.wav',
        );
      }
      alignStatus = LoadStatus.ok;
      alignMessage = 'Ausrichtung fertig.';
    } catch (e) {
      alignStatus = LoadStatus.error;
      alignMessage = 'Ausrichtung fehlgeschlagen: ${_messageOf(e)}';
      // alignedSungCurve bleibt leer - displayedSungCurve faellt automatisch auf
      // die rohe sungCurve zurueck (siehe Getter oben).
    }
    notifyListeners();
  }

  Future<void> analyzeReference(Uint8List bytes, String filename) async {
    referenceAudioBytes = bytes;
    referenceStatus = LoadStatus.loading;
    referenceMessage = 'Analysiere Referenzaufnahme…';
    notifyListeners();
    try {
      referenceRawCurve = await audioApi.analyzeAudio(bytes, filename);
      referenceStatus = LoadStatus.ok;
      referenceMessage =
          'Referenz analysiert. Jetzt eine Gesangsaufnahme aufnehmen oder hochladen.';
    } catch (e) {
      referenceStatus = LoadStatus.error;
      referenceMessage = 'Fehler: ${_messageOf(e)}';
    }
    notifyListeners();
  }

  void setReferenceSource(ReferenceSource source) {
    if (source == referenceSource) return;
    referenceSource = source;
    sungCurve = [];
    sungAudioBytes = null;
    audioStatus = LoadStatus.idle;
    audioMessage = '';
    alignedSungCurve = [];
    alignStatus = LoadStatus.idle;
    alignMessage = '';
    notifyListeners();
  }

  void _resetAudioSection() {
    selectedTrackIndex = null;
    targetCurve = [];
    sungCurve = [];
    sungAudioBytes = null;
    audioStatus = LoadStatus.idle;
    audioMessage = '';
    alignedSungCurve = [];
    alignStatus = LoadStatus.idle;
    alignMessage = '';
  }

  String _messageOf(Object e) => e is ApiException ? e.message : e.toString();
}
