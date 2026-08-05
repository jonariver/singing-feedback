import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/audio_api.dart';
import '../api/midi_api.dart';
import '../models/sung_point.dart';
import '../models/target_point.dart';
import '../models/track_candidate.dart';

enum LoadStatus { idle, loading, ok, error }

/// Spiegelt das `state`-Objekt aus frontend/app.js als ChangeNotifier, damit die
/// Widgets denselben Ablauf (MIDI-Upload -> Spurwahl -> Aufnahme -> Kurven) fahren.
class SessionState extends ChangeNotifier {
  final MidiApi midiApi;
  final AudioApi audioApi;

  SessionState({required this.midiApi, required this.audioApi});

  String? midiSessionId;
  List<TrackCandidate> candidates = [];
  int? selectedTrackIndex;
  int transposeSemitones = 0;
  List<TargetPoint> targetCurve = [];
  List<SungPoint> sungCurve = [];

  LoadStatus midiStatus = LoadStatus.idle;
  String midiMessage = '';
  LoadStatus audioStatus = LoadStatus.idle;
  String audioMessage = '';

  bool get audioSectionEnabled => selectedTrackIndex != null;

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
    audioStatus = LoadStatus.loading;
    audioMessage = 'Analysiere Tonhöhe der Aufnahme…';
    notifyListeners();
    try {
      sungCurve = await audioApi.analyzeAudio(bytes, filename);
      audioStatus = LoadStatus.ok;
      audioMessage = 'Analyse fertig.';
    } catch (e) {
      audioStatus = LoadStatus.error;
      audioMessage = 'Fehler: ${_messageOf(e)}';
    }
    notifyListeners();
  }

  void _resetAudioSection() {
    selectedTrackIndex = null;
    targetCurve = [];
    sungCurve = [];
    audioStatus = LoadStatus.idle;
    audioMessage = '';
  }

  String _messageOf(Object e) => e is ApiException ? e.message : e.toString();
}
