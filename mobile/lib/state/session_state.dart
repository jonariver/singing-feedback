import 'dart:async';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../api/audio_api.dart';
import '../api/midi_api.dart';
import '../api/score_api.dart';
import '../api/feedback_api.dart';
import '../models/feedback_result.dart';
import '../api/sync_api.dart';
import '../models/score_result.dart';
import '../models/sung_point.dart';
import '../models/target_point.dart';
import '../models/tolerance_preset.dart';
import '../models/track_candidate.dart';

enum LoadStatus { idle, loading, ok, warning, error }

enum ReferenceSource { midi, recording }

const String _tolerancePresetPrefsKey = 'tolerance_preset';

/// Formatiert eine Sekundenzahl als m:ss, z.B. fuer Kuerzungs-Warnmeldungen
/// ("Aufnahme war 1:56 lang..."). Rundet auf ganze Sekunden.
String formatDurationMinSec(double seconds) {
  final totalSeconds = seconds.round();
  final minutes = totalSeconds ~/ 60;
  final secs = totalSeconds % 60;
  return '$minutes:${secs.toString().padLeft(2, '0')}';
}

/// Duenne Abstraktion ueber die Audio-Wiedergabe, injizierbar fuer Tests. Lebt hier
/// (nicht mehr in playback_button.dart), weil SessionState jetzt den einen zentralen
/// Player fuer die ganze App besitzt - PlaybackButton und die Feedback-Sprungbuttons
/// teilen sich ihn, damit nie zwei Wiedergaben gleichzeitig laufen.
abstract class AudioPlaybackController {
  Future<void> play(Uint8List bytes);
  Future<void> playFrom(Uint8List bytes, Duration position);
  Future<void> pause();
  Future<void> stop();
  Stream<void> get onComplete;
  Stream<Duration> get onPositionChanged;
  Stream<Duration> get onDurationChanged;
  void dispose();
}

/// Standardimplementierung, delegiert an das echte audioplayers-Paket.
class _RealAudioPlaybackController implements AudioPlaybackController {
  final AudioPlayer _player = AudioPlayer();

  @override
  Future<void> play(Uint8List bytes) => _player.play(BytesSource(bytes));

  @override
  Future<void> playFrom(Uint8List bytes, Duration position) =>
      _player.play(BytesSource(bytes), position: position);

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() => _player.stop();

  @override
  Stream<void> get onComplete => _player.onPlayerComplete;

  @override
  Stream<Duration> get onPositionChanged => _player.onPositionChanged;

  @override
  Stream<Duration> get onDurationChanged => _player.onDurationChanged;

  @override
  void dispose() {
    unawaited(_player.dispose());
  }
}

/// Spiegelt das `state`-Objekt aus frontend/app.js als ChangeNotifier, damit die
/// Widgets denselben Ablauf (MIDI-Upload -> Spurwahl -> Aufnahme -> Kurven) fahren.
class SessionState extends ChangeNotifier {
  final MidiApi midiApi;
  final AudioApi audioApi;
  final SyncApi syncApi;
  final ScoreApi scoreApi;
  final FeedbackApi feedbackApi;
  final AudioPlaybackController Function() _playbackControllerFactory;

  SessionState({
    required this.midiApi,
    required this.audioApi,
    required this.syncApi,
    required this.scoreApi,
    required this.feedbackApi,
    AudioPlaybackController Function()? playbackControllerFactory,
  }) : _playbackControllerFactory =
            playbackControllerFactory ?? (() => _RealAudioPlaybackController());

  AudioPlaybackController? _playbackControllerInstance;
  StreamSubscription<void>? _playbackCompleteSubscription;
  bool isPlaying = false;
  Uint8List? _playingBytes;
  Object? _playbackGeneration;
  Object? _scoreGeneration;

  /// Baut den Player erst beim ersten tatsaechlichen Gebrauch (nicht im Konstruktor) -
  /// sonst wuerde jeder Test, der irgendwo eine SessionState baut, unabhaengig davon ob
  /// er Wiedergabe ueberhaupt testet, einen echten AudioPlayer() samt unawaited
  /// Plattform-Kanal-Aufrufen anstossen.
  AudioPlaybackController get _playbackController {
    var instance = _playbackControllerInstance;
    if (instance == null) {
      instance = _playbackControllerFactory();
      _playbackControllerInstance = instance;
      _playbackCompleteSubscription = instance.onComplete.listen((_) {
        isPlaying = false;
        notifyListeners();
      });
    }
    return instance;
  }

  /// Ob genau diese Bytes (Objekt-Identitaet - reicht, da sungAudioBytes/
  /// referenceAudioBytes stabile Referenzen sind, die nicht bei jedem Rebuild neu
  /// erzeugt werden) gerade abgespielt werden. Damit koennen mehrere PlaybackButton-
  /// Instanzen (Referenz- und Gesangsaufnahme) trotz gemeinsamem Player weiterhin
  /// unabhaengig ihren eigenen Play/Pause-Icon-Status anzeigen.
  bool isPlayingAudio(Uint8List? bytes) =>
      isPlaying && bytes != null && identical(_playingBytes, bytes);

  Future<void> play(Uint8List bytes) async {
    final generation = _playbackGeneration = Object();
    _playingBytes = bytes;
    await _playbackController.play(bytes);
    if (generation != _playbackGeneration) return;
    isPlaying = true;
    notifyListeners();
  }

  Future<void> playFrom(Uint8List bytes, Duration position) async {
    final generation = _playbackGeneration = Object();
    _playingBytes = bytes;
    await _playbackController.playFrom(bytes, position);
    if (generation != _playbackGeneration) return;
    isPlaying = true;
    notifyListeners();
  }

  Future<void> pause() async {
    final generation = _playbackGeneration = Object();
    await _playbackController.pause();
    if (generation != _playbackGeneration) return;
    isPlaying = false;
    notifyListeners();
  }

  Future<void> stop() async {
    // Wurde noch nie tatsaechlich abgespielt (Controller nie gebaut), gibt es per
    // Definition nichts zu stoppen - fruehzeitig raus, BEVOR der (lazy gebaute)
    // _playbackController-Getter angefasst wird. Sonst wuerde z.B. setReferenceSource()
    // (das stop() unbedingt aufruft) in jedem Test/Aufruf einen echten AudioPlayer()
    // samt Plattform-Kanal-Zugriff anstossen, selbst wenn nie etwas lief (siehe
    // Kommentar am _playbackController-Getter oben).
    if (_playbackControllerInstance == null) return;
    final generation = _playbackGeneration = Object();
    await _playbackController.stop();
    if (generation != _playbackGeneration) return;
    isPlaying = false;
    _playingBytes = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _playbackCompleteSubscription?.cancel();
    _playbackControllerInstance?.dispose();
    super.dispose();
  }

  String? midiSessionId;
  List<TrackCandidate> candidates = [];
  final Map<int, Uint8List> _trackPreviewCache = {};
  int? selectedTrackIndex;
  int transposeSemitones = 0;
  int referenceTransposeSemitones = 0;
  List<TargetPoint> targetCurve = [];
  List<SungPoint> sungCurve = [];

  LoadStatus midiStatus = LoadStatus.idle;
  String midiMessage = '';
  LoadStatus audioStatus = LoadStatus.idle;
  String audioMessage = '';

  ReferenceSource referenceSource = ReferenceSource.recording;
  List<SungPoint> referenceRawCurve = [];
  LoadStatus referenceStatus = LoadStatus.idle;
  String referenceMessage = '';
  Uint8List? referenceAudioBytes;
  Uint8List? sungAudioBytes;
  String? sungAudioFilename;
  bool audioTruncated = false;
  bool referenceTruncated = false;

  List<SungPoint> alignedSungCurve = [];
  LoadStatus alignStatus = LoadStatus.idle;
  String alignMessage = '';

  /// Toleranz-Preset fuer die gruen/gelb/rot-Klassifikation der Cent-Abweichung
  /// (siehe docs/superpowers/specs/2026-08-07-tolerance-preset-design.md).
  /// Startet synchron mit dem Default; ein zuvor gespeicherter Wert wird erst
  /// asynchron per loadPersistedTolerancePreset() nachgeladen (siehe dort).
  TolerancePreset tolerancePreset = TolerancePreset.normal;

  ScoreResult? scoreResult;
  LoadStatus scoreStatus = LoadStatus.idle;
  String scoreMessage = '';

  FeedbackResult? feedbackResult;
  LoadStatus feedbackStatus = LoadStatus.idle;
  String feedbackMessage = '';

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
    _trackPreviewCache.clear();
    // Der geteilte Player (siehe Klassenkommentar oben) koennte gerade eine
    // Track-Vorschau abspielen - der Cache-Clear oben loescht die Bytes, gegen die
    // isPlayingAudio() vergleicht, also kann kein TrackPreviewButton mehr "Pause"
    // anzeigen, waehrend die Wiedergabe unsichtbar unbegrenzt weiterliefe. Gleiches
    // Muster wie setReferenceSource() unten.
    unawaited(stop());
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
    // Die neue Spur ist eine andere Zielmelodie - ein zuvor gegen die alte Spur
    // berechnetes Alignment waere jetzt still falsch (siehe align()-Kommentar).
    _resetAlignment();
    notifyListeners();
    await _reloadTargetCurve();
  }

  /// Bereits geladene Vorschau-Bytes fuer einen Track, falls vorhanden - sync,
  /// fuer den Play/Pause-Icon-Status (siehe isPlayingAudio-Identitaetsvergleich).
  Uint8List? cachedPreviewBytes(int trackIndex) => _trackPreviewCache[trackIndex];

  /// Holt die Hoerprobe fuer einen Track lazy und cacht sie; wiederholte Aufrufe
  /// fuer denselben Track loesen keinen erneuten Request aus. Transponierung ist
  /// bewusst nicht beruecksichtigt (Vorschau ist immer in Originaltonlage, hilft
  /// bei der Spurwahl vor dem Transponieren).
  Future<Uint8List> previewBytesForTrack(int trackIndex) async {
    final cached = _trackPreviewCache[trackIndex];
    if (cached != null) return cached;
    final bytes = await midiApi.fetchTrackPreview(midiSessionId!, trackIndex);
    _trackPreviewCache[trackIndex] = bytes;
    return bytes;
  }

  Future<void> setTranspose(int semitones) async {
    if (referenceSource == ReferenceSource.recording) {
      referenceTransposeSemitones = semitones;
      notifyListeners();
      if (alignedSungCurve.isNotEmpty) await score();
      return;
    }
    if (selectedTrackIndex == null) return;
    transposeSemitones = semitones;
    await _reloadTargetCurve();
    if (alignedSungCurve.isNotEmpty) await score();
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

  Future<void> setTolerancePreset(TolerancePreset preset) async {
    tolerancePreset = preset;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tolerancePresetPrefsKey, preset.apiValue);
    if (alignedSungCurve.isNotEmpty) await score();
  }

  /// Laedt ein zuvor gespeichertes Toleranz-Preset (falls vorhanden) und wendet
  /// es an - bewusst NICHT im Konstruktor, sondern nur von main.dart nach dem
  /// Bauen dieser SessionState aufgerufen (fire-and-forget), damit kein Test,
  /// der eine SessionState baut, ungewollt einen SharedPreferences-
  /// Plattform-Kanal-Zugriff ausloest (gleiches Prinzip wie beim lazy
  /// _playbackController weiter oben in dieser Datei).
  Future<void> loadPersistedTolerancePreset() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = TolerancePreset.fromApiValue(prefs.getString(_tolerancePresetPrefsKey));
    if (stored != null && stored != tolerancePreset) {
      tolerancePreset = stored;
      notifyListeners();
    }
  }

  Future<void> analyzeAudio(Uint8List bytes, String filename) async {
    sungAudioBytes = bytes;
    sungAudioFilename = filename;
    audioStatus = LoadStatus.loading;
    audioMessage = 'Analysiere Tonhöhe der Aufnahme…';
    _resetAlignment();
    notifyListeners();
    try {
      final result = await audioApi.analyzeAudio(bytes, filename);
      sungCurve = result.curve;
      audioTruncated = result.truncated;
      audioStatus = result.truncated ? LoadStatus.warning : LoadStatus.ok;
      audioMessage = result.truncated
          ? 'Analyse fertig. Achtung: Aufnahme war '
              '${formatDurationMinSec(result.originalDurationSeconds)} lang und wurde auf '
              '${formatDurationMinSec(result.curve.isNotEmpty ? result.curve.last.t : 0)} gekürzt.'
          : 'Analyse fertig.';
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
      notifyListeners();
      await score();
      return;
    } catch (e) {
      alignStatus = LoadStatus.error;
      alignMessage = 'Ausrichtung fehlgeschlagen: ${_messageOf(e)}';
      // alignedSungCurve bleibt leer - displayedSungCurve faellt automatisch auf
      // die rohe sungCurve zurueck (siehe Getter oben).
    }
    notifyListeners();
  }

  /// Bewertet die ausgerichtete Gesangskurve gegen die Zielmelodie (POST /api/score).
  /// Wird automatisch am Ende eines erfolgreichen align() angestossen und erneut nach
  /// jeder Transpose-Aenderung (siehe setTranspose) - kein manueller Button. Nutzt
  /// displayedTargetCurve (die auch im Chart gezeigte, ggf. transponierte Kurve): DTW-
  /// Alignment selbst haengt nie von Transpose ab (laeuft nur auf der Onset-Huellkurve,
  /// nie auf Tonhoehe), aber die Bewertung IST tonhoehen-abhaengig - Chart und Bewertung
  /// muessen dieselbe (ggf. transponierte) Zielkurve zeigen bzw. bewerten, sonst
  /// widersprechen sie sich sichtbar.
  Future<void> score() async {
    if (alignedSungCurve.isEmpty) return;
    final generation = _scoreGeneration = Object();
    feedbackResult = null;
    feedbackStatus = LoadStatus.idle;
    feedbackMessage = '';
    scoreStatus = LoadStatus.loading;
    scoreMessage = 'Werte Aufnahme aus…';
    notifyListeners();
    try {
      final targetCurveJson = displayedTargetCurve.map((p) => p.toJson()).toList();
      final result = await scoreApi.score(targetCurveJson, alignedSungCurve, tolerancePreset);
      if (generation != _scoreGeneration) return;
      scoreResult = result;
      scoreStatus = LoadStatus.ok;
      scoreMessage = 'Bewertung fertig.';
    } catch (e) {
      if (generation != _scoreGeneration) return;
      scoreStatus = LoadStatus.error;
      scoreMessage = 'Bewertung fehlgeschlagen: ${_messageOf(e)}';
    }
    notifyListeners();
  }

  /// Fordert Claude-generiertes Feedback zur aktuellen Bewertung an (POST
  /// /api/feedback). Nur auf Nutzer-Wunsch (Button in HomeScreen), kein
  /// Auto-Trigger wie bei align()/score() - jeder Aufruf loest eine echte,
  /// kostenpflichtige Anthropic-API-Anfrage aus.
  Future<void> requestFeedback() async {
    // Synchroner Guard vor dem ersten await: verhindert, dass ein schneller
    // Doppel-Tap (innerhalb des Frames, bevor der disabled-Zustand des Buttons
    // sichtbar wird) zwei parallele, beide kostenpflichtige Anthropic-Aufrufe
    // ausloest - gleiches Muster wie PlaybackButton/ShareButton.
    if (feedbackStatus == LoadStatus.loading) return;
    if (scoreResult == null) return;
    feedbackStatus = LoadStatus.loading;
    feedbackMessage = 'Hole Feedback…';
    notifyListeners();
    try {
      feedbackResult = await feedbackApi.requestFeedback(scoreResult!.toJson());
      feedbackStatus = LoadStatus.ok;
      feedbackMessage = 'Feedback fertig.';
    } catch (e) {
      feedbackStatus = LoadStatus.error;
      feedbackMessage = 'Feedback fehlgeschlagen: ${_messageOf(e)}';
    }
    notifyListeners();
  }

  Future<void> analyzeReference(Uint8List bytes, String filename) async {
    referenceAudioBytes = bytes;
    referenceStatus = LoadStatus.loading;
    referenceMessage = 'Analysiere Referenzaufnahme…';
    // Neue Referenzaufnahme = neue Zielmelodie - siehe selectTrack() oben.
    _resetAlignment();
    notifyListeners();
    try {
      final result = await audioApi.analyzeAudio(bytes, filename);
      referenceRawCurve = result.curve;
      referenceTruncated = result.truncated;
      referenceStatus = result.truncated ? LoadStatus.warning : LoadStatus.ok;
      referenceMessage = result.truncated
          ? 'Referenz analysiert. Achtung: Aufnahme war '
              '${formatDurationMinSec(result.originalDurationSeconds)} lang und wurde auf '
              '${formatDurationMinSec(result.curve.isNotEmpty ? result.curve.last.t : 0)} gekürzt. '
              'Jetzt eine Gesangsaufnahme aufnehmen oder hochladen.'
          : 'Referenz analysiert. Jetzt eine Gesangsaufnahme aufnehmen oder hochladen.';
    } catch (e) {
      referenceStatus = LoadStatus.error;
      referenceMessage = 'Fehler: ${_messageOf(e)}';
    }
    notifyListeners();
  }

  void setReferenceSource(ReferenceSource source) {
    if (source == referenceSource) return;
    // Der geteilte Player (siehe Klassenkommentar oben) koennte gerade Referenz- oder
    // Gesangsbytes abspielen - beide werden durch den Moduswechsel gleich behandelt
    // (sungAudioBytes unten zurueckgesetzt, referenceAudioBytes bleibt zwar erhalten,
    // aber der zugehoerige PlaybackButton verschwindet aus dem Baum). Ohne diesen
    // Stop wuerde eine laufende Wiedergabe unsichtbar (kein Icon im Baum kann sie mehr
    // stoppen) und unbegrenzt weiterlaufen.
    unawaited(stop());
    referenceSource = source;
    sungCurve = [];
    sungAudioBytes = null;
    sungAudioFilename = null;
    audioStatus = LoadStatus.idle;
    audioMessage = '';
    audioTruncated = false;
    _resetAlignment();
    notifyListeners();
  }

  void _resetAudioSection() {
    selectedTrackIndex = null;
    targetCurve = [];
    sungCurve = [];
    sungAudioBytes = null;
    sungAudioFilename = null;
    audioStatus = LoadStatus.idle;
    audioMessage = '';
    audioTruncated = false;
    _resetAlignment();
  }

  /// Verwirft ein zuvor berechnetes Alignment. Muss ueberall dort aufgerufen werden,
  /// wo sich entweder die Zielmelodie (selectTrack, analyzeReference) oder die
  /// gesungene Aufnahme (_resetAudioSection, setReferenceSource) aendert - ein
  /// stehen gelassenes alignedSungCurve waere sonst gegen eine andere Zielmelodie
  /// bzw. Aufnahme berechnet und wuerde still falsch im Chart landen.
  void _resetAlignment() {
    alignedSungCurve = [];
    alignStatus = LoadStatus.idle;
    alignMessage = '';
    scoreResult = null;
    scoreStatus = LoadStatus.idle;
    scoreMessage = '';
    feedbackResult = null;
    feedbackStatus = LoadStatus.idle;
    feedbackMessage = '';
  }

  String _messageOf(Object e) => e is ApiException ? e.message : e.toString();
}
