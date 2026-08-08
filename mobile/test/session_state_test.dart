import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:singing_feedback_mobile/api/api_client.dart';
import 'package:singing_feedback_mobile/api/audio_api.dart';
import 'package:singing_feedback_mobile/api/midi_api.dart';
import 'package:singing_feedback_mobile/api/score_api.dart';
import 'package:singing_feedback_mobile/api/feedback_api.dart';
import 'package:singing_feedback_mobile/api/sync_api.dart';
import 'package:singing_feedback_mobile/models/target_point.dart';
import 'package:singing_feedback_mobile/state/session_state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:singing_feedback_mobile/models/tolerance_preset.dart';

class _FakeApiClient extends ApiClient {
  _FakeApiClient() : super(baseUrl: 'http://fake.local');

  Map<String, dynamic>? lastPostJsonBody;

  @override
  Future<Map<String, dynamic>> postMultipart(
    String path, {
    required String fieldName,
    required Uint8List bytes,
    required String filename,
    Map<String, String>? fields,
    String? secondFieldName,
    Uint8List? secondBytes,
    String? secondFilename,
  }) async {
    if (path == '/api/sync/align') {
      return {
        'target_curve': [
          {'t': 0.0, 'hz': 440.0, 'midi_note': 69},
        ],
        'sung_curve': [
          {'t': 0.0, 'hz': 440.0, 'voiced': true, 'confidence': 0.9, 'aligned_t': 0.05},
          {'t': 0.01, 'hz': null, 'voiced': false, 'confidence': 0.0, 'aligned_t': null},
        ],
        'target_duration': 1.0,
      };
    }
    return {
      'curve': [
        {'t': 0.0, 'hz': 440.0, 'voiced': true, 'confidence': 0.9},
        {'t': 0.01, 'hz': null, 'voiced': false, 'confidence': 0.0},
      ],
      'truncated': false,
      'original_duration_seconds': 0.02,
    };
  }

  Object? throwOnFeedback;
  int feedbackCallCount = 0;
  Map<String, dynamic> feedbackResponse = {
    'feedback': {
      'points': [
        {
          'problem': 'Timing daneben',
          'technik': 'Testtechnik',
          'uebung': 'Testuebung',
          'wiederholungsaufgabe': null,
        },
      ],
    },
  };

  @override
  Future<Map<String, dynamic>> postJson(String path, Map<String, dynamic> body) async {
    lastPostJsonBody = body;
    if (path == '/api/feedback') {
      feedbackCallCount++;
      if (throwOnFeedback != null) throw throwOnFeedback!;
      return feedbackResponse;
    }
    return {
      'score': {
        'notes': [
          {
            'index': 0, 'start_t': 0.0, 'end_t': 1.0,
            'target_hz': 440.0, 'target_midi_note': 69,
            'missed': false, 'coverage_fraction': 1.0,
            'cents_deviation': {'value': 1.2, 'classification': 'green'},
            'timing': {'deviation_ms': 4.0, 'classification': 'on_time'},
            'held': true,
            'stability': {'applicable': true, 'mad_cents': 0.8, 'flag': false},
            'phrase_end_drift': {'applicable': true, 'drift_cents': 0.3, 'flag': false, 'direction': null},
            'glide': {'applicable': true, 'onset_cents_deviation': -62.0, 'flag': true, 'direction': 'up'},
            'sung_t': 0.12,
          },
        ],
        'summary': {
          'note_count': 1, 'missed_count': 0,
          'cents_green': 1, 'cents_yellow': 0, 'cents_red': 0,
          'timing_flagged_count': 0, 'stability_flagged_count': 0,
          'phrase_end_drift_flagged_count': 0,
          'glide_flagged_count': 1,
          'overall_score': 100.0,
          'problem_tags': <String>[],
          'vocal_range': {
            'applicable': false,
            'min_hz': null,
            'max_hz': null,
            'min_midi_note': null,
            'max_midi_note': null,
          },
        },
      },
    };
  }

  int getBytesCallCount = 0;

  @override
  Future<Uint8List> getBytes(String path, {Map<String, String>? query}) async {
    getBytesCallCount++;
    return Uint8List.fromList([1, 2, 3, 4]);
  }
}

class _TruncatingFakeApiClient extends ApiClient {
  _TruncatingFakeApiClient() : super(baseUrl: 'http://fake.local');

  @override
  Future<Map<String, dynamic>> postMultipart(
    String path, {
    required String fieldName,
    required Uint8List bytes,
    required String filename,
    Map<String, String>? fields,
    String? secondFieldName,
    Uint8List? secondBytes,
    String? secondFilename,
  }) async {
    return {
      'curve': [
        {'t': 0.0, 'hz': 440.0, 'voiced': true, 'confidence': 0.9},
        {'t': 90.0, 'hz': 440.0, 'voiced': true, 'confidence': 0.9},
      ],
      'truncated': true,
      'original_duration_seconds': 116.0,
    };
  }
}

/// Fake-Implementierung von [AudioPlaybackController] fuer Tests, ganz ohne echten
/// Plattform-Kanal - gleiches Muster wie in playback_button_test.dart. [play]/
/// [playFrom]/[pause]/[stop] koennen ueber die jeweiligen Completer auf "haengend"
/// gehalten werden, um Await-Race-Szenarien (Generation-Guard) zu simulieren.
class _FakePlaybackController implements AudioPlaybackController {
  Completer<void>? playCompleter;
  Completer<void>? playFromCompleter;
  Completer<void>? pauseCompleter;
  Completer<void>? stopCompleter;
  int playCallCount = 0;
  int playFromCallCount = 0;
  int pauseCallCount = 0;
  int stopCallCount = 0;
  final _completeController = StreamController<void>.broadcast();
  final _positionChangedController = StreamController<Duration>.broadcast();
  final _durationChangedController = StreamController<Duration>.broadcast();

  @override
  Future<void> play(Uint8List bytes) async {
    playCallCount++;
    if (playCompleter != null) await playCompleter!.future;
  }

  @override
  Future<void> playFrom(Uint8List bytes, Duration position) async {
    playFromCallCount++;
    if (playFromCompleter != null) await playFromCompleter!.future;
  }

  @override
  Future<void> pause() async {
    pauseCallCount++;
    if (pauseCompleter != null) await pauseCompleter!.future;
  }

  @override
  Future<void> stop() async {
    stopCallCount++;
    if (stopCompleter != null) await stopCompleter!.future;
  }

  @override
  Stream<void> get onComplete => _completeController.stream;

  @override
  Stream<Duration> get onPositionChanged => _positionChangedController.stream;

  @override
  Stream<Duration> get onDurationChanged => _durationChangedController.stream;

  @override
  void dispose() {
    unawaited(_completeController.close());
    unawaited(_positionChangedController.close());
    unawaited(_durationChangedController.close());
  }
}

SessionState _buildSession() {
  final client = _FakeApiClient();
  return SessionState(
    midiApi: MidiApi(client),
    audioApi: AudioApi(client),
    syncApi: SyncApi(client),
    scoreApi: ScoreApi(client),
    feedbackApi: FeedbackApi(client),
  );
}

SessionState _buildSessionWithPlayback(AudioPlaybackController fake) {
  final client = _FakeApiClient();
  return SessionState(
    midiApi: MidiApi(client),
    audioApi: AudioApi(client),
    syncApi: SyncApi(client),
    scoreApi: ScoreApi(client),
    feedbackApi: FeedbackApi(client),
    playbackControllerFactory: () => fake,
  );
}

void main() {
  SharedPreferences.setMockInitialValues({});

  test('displayedTargetCurve liefert im MIDI-Modus targetCurve unveraendert', () {
    final session = _buildSession();
    session.setReferenceSource(ReferenceSource.midi);
    session.targetCurve = const [TargetPoint(t: 0.0, hz: 220.0, midiNote: 57)];

    expect(session.referenceSource, ReferenceSource.midi);
    expect(session.displayedTargetCurve, session.targetCurve);
  });

  test('analyzeReference befuellt referenceRawCurve und displayedTargetCurve im Referenz-Modus', () async {
    final session = _buildSession();
    session.setReferenceSource(ReferenceSource.recording);

    await session.analyzeReference(Uint8List(0), 'referenz.wav');

    expect(session.referenceStatus, LoadStatus.ok);
    expect(session.referenceRawCurve.length, 2);
    expect(session.displayedTargetCurve[0].hz, closeTo(440.0, 0.001));
    expect(session.displayedTargetCurve[0].midiNote, isNull);
    expect(session.displayedTargetCurve[1].hz, isNull);
  });

  test('setTranspose verschiebt die Referenzkurve rein rechnerisch ohne erneuten Netzwerkaufruf', () async {
    final session = _buildSession();
    session.setReferenceSource(ReferenceSource.recording);
    await session.analyzeReference(Uint8List(0), 'referenz.wav');
    final curveBeforeTranspose = session.referenceRawCurve;

    await session.setTranspose(12);

    expect(session.referenceTransposeSemitones, 12);
    expect(session.displayedTranspose, 12);
    expect(session.displayedTargetCurve[0].hz, closeTo(440.0 * math.pow(2, 1), 0.01));
    // Keine erneute Analyse ausgeloest: dieselbe Roh-Kurven-Instanz wie vor dem Transpose.
    expect(identical(session.referenceRawCurve, curveBeforeTranspose), isTrue);
  });

  test('audioSectionEnabled haengt im Referenz-Modus von referenceRawCurve ab', () async {
    final session = _buildSession();
    session.setReferenceSource(ReferenceSource.recording);
    expect(session.audioSectionEnabled, isFalse);

    await session.analyzeReference(Uint8List(0), 'referenz.wav');
    expect(session.audioSectionEnabled, isTrue);
  });

  test('setReferenceSource wechselt zurueck ohne referenceRawCurve zu verwerfen', () async {
    final session = _buildSession();
    session.setReferenceSource(ReferenceSource.recording);
    await session.analyzeReference(Uint8List(0), 'referenz.wav');

    session.setReferenceSource(ReferenceSource.midi);
    session.setReferenceSource(ReferenceSource.recording);

    expect(session.referenceRawCurve.length, 2);
  });

  test(
      'transponieren im Referenz-Modus laesst den MIDI-Transpose und dessen '
      'targetCurve unangetastet (Regression fuer Desync beim Moduswechsel)',
      () async {
    final session = _buildSession();
    session.setReferenceSource(ReferenceSource.midi);
    // MIDI-Modus: Spur ausgewaehlt, targetCurve wie vom Server fuer +5 Halbtoene
    // zurueckgeliefert simulieren, ohne einen echten MIDI-Upload zu benoetigen.
    session.selectedTrackIndex = 0;
    session.targetCurve = const [TargetPoint(t: 0.0, hz: 220.0, midiNote: 57)];
    await session.setTranspose(5);

    expect(session.transposeSemitones, 5);
    expect(session.displayedTranspose, 5);
    final targetCurveAfterMidiTranspose = session.targetCurve;

    // Wechsel in den Referenz-Modus, Referenz laden und dort einen anderen
    // Transpose-Wert setzen. Das darf transposeSemitones/targetCurve nicht anfassen.
    session.setReferenceSource(ReferenceSource.recording);
    await session.analyzeReference(Uint8List(0), 'referenz.wav');
    await session.setTranspose(0);

    expect(session.referenceTransposeSemitones, 0);
    expect(session.displayedTranspose, 0);
    expect(session.transposeSemitones, 5,
        reason: 'MIDI-Transpose darf durch den Referenz-Modus nicht ueberschrieben werden');

    // Zurueck zu MIDI: Regler und Kurve muessen wieder den +5-Zustand zeigen,
    // nicht den zuletzt im Referenz-Modus gesetzten Wert (0).
    session.setReferenceSource(ReferenceSource.midi);

    expect(session.displayedTranspose, 5);
    expect(session.transposeSemitones, 5);
    expect(session.displayedTargetCurve, targetCurveAfterMidiTranspose);
  });

  test('analyzeAudio und analyzeReference setzen die Roh-Audio-Bytes fuer Playback-nach-Upload',
      () async {
    final session = _buildSession();
    final referenceBytes = Uint8List.fromList([1, 2, 3]);
    final sungBytes = Uint8List.fromList([4, 5, 6]);

    session.setReferenceSource(ReferenceSource.recording);
    await session.analyzeReference(referenceBytes, 'referenz.wav');
    await session.analyzeAudio(sungBytes, 'gesang.wav');

    expect(session.referenceAudioBytes, referenceBytes);
    expect(session.sungAudioBytes, sungBytes);
  });

  test('setReferenceSource setzt sungAudioBytes zurueck, referenceAudioBytes bleibt erhalten',
      () async {
    final session = _buildSession();
    session.setReferenceSource(ReferenceSource.recording);
    await session.analyzeReference(Uint8List.fromList([1, 2, 3]), 'referenz.wav');
    await session.analyzeAudio(Uint8List.fromList([4, 5, 6]), 'gesang.wav');

    session.setReferenceSource(ReferenceSource.midi);

    expect(session.sungAudioBytes, isNull);
    expect(session.referenceAudioBytes, isNotNull);
  });

  test('analyzeAudio loest automatisch align() aus und befuellt alignedSungCurve (MIDI-Modus)',
      () async {
    final session = _buildSession();
    session.setReferenceSource(ReferenceSource.midi);
    session.midiSessionId = 'sess-1';
    session.selectedTrackIndex = 0;

    await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.wav');

    expect(session.alignStatus, LoadStatus.ok);
    expect(session.alignedSungCurve.length, 2);
    expect(session.alignedSungCurve[0].alignedT, closeTo(0.05, 0.001));
    expect(session.displayedSungCurve, session.alignedSungCurve);
  });

  test('analyzeAudio loest align() im Referenz-Modus mit reference_audio aus', () async {
    final session = _buildSession();
    session.setReferenceSource(ReferenceSource.recording);
    await session.analyzeReference(Uint8List.fromList([9, 9, 9]), 'referenz.wav');

    await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.wav');

    expect(session.alignStatus, LoadStatus.ok);
    expect(session.alignedSungCurve.length, 2);
  });

  test('displayedSungCurve faellt ohne Alignment auf die rohe sungCurve zurueck', () {
    final session = _buildSession();
    expect(session.alignedSungCurve, isEmpty);
    expect(session.displayedSungCurve, session.sungCurve);
  });

  test('align() schlaegt im MIDI-Modus ohne ausgewaehlte Spur fehl, ohne sungCurve zu veraendern',
      () async {
    final session = _buildSession();
    // Kein midiSessionId/selectedTrackIndex gesetzt.
    await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.wav');

    expect(session.audioStatus, LoadStatus.ok);
    expect(session.alignStatus, LoadStatus.error);
    expect(session.alignedSungCurve, isEmpty);
    expect(session.displayedSungCurve, session.sungCurve);
  });

  test('setReferenceSource setzt alignedSungCurve/alignStatus zurueck', () async {
    final session = _buildSession();
    session.setReferenceSource(ReferenceSource.midi);
    session.midiSessionId = 'sess-1';
    session.selectedTrackIndex = 0;
    await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.wav');
    expect(session.alignedSungCurve, isNotEmpty);

    session.setReferenceSource(ReferenceSource.recording);

    expect(session.alignedSungCurve, isEmpty);
    expect(session.alignStatus, LoadStatus.idle);
  });

  test('selectTrack setzt alignedSungCurve/alignStatus zurueck (neue Zielmelodie)', () async {
    final session = _buildSession();
    session.setReferenceSource(ReferenceSource.midi);
    session.midiSessionId = 'sess-1';
    session.selectedTrackIndex = 0;
    await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.wav');
    expect(session.alignedSungCurve, isNotEmpty);
    expect(session.alignStatus, LoadStatus.ok);

    // Wahl einer anderen Spur: der Netzwerkaufruf fuer die neue Zielkurve
    // (midiApi.getTrackCurve -> ApiClient.get) ist in _FakeApiClient nicht
    // gefaked und schlaegt daher fehl - relevant ist hier nur, dass das
    // Alignment synchron VOR diesem Aufruf zurueckgesetzt wird.
    await session.selectTrack(1);

    expect(session.alignedSungCurve, isEmpty);
    expect(session.alignStatus, LoadStatus.idle);
  });

  test(
      'analyzeReference setzt alignedSungCurve/alignStatus zurueck (neue Zielmelodie im '
      'Referenz-Modus)', () async {
    final session = _buildSession();
    session.setReferenceSource(ReferenceSource.recording);
    await session.analyzeReference(Uint8List.fromList([9, 9, 9]), 'referenz.wav');
    await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.wav');
    expect(session.alignedSungCurve, isNotEmpty);
    expect(session.alignStatus, LoadStatus.ok);

    // Neue Referenzaufnahme = neue Zielmelodie -> das alte Alignment (gegen die
    // vorherige Referenz berechnet) darf nicht stehen bleiben.
    await session.analyzeReference(Uint8List.fromList([7, 7, 7]), 'referenz2.wav');

    expect(session.alignedSungCurve, isEmpty);
    expect(session.alignStatus, LoadStatus.idle);
  });

  test('align() loest automatisch score() aus und befuellt scoreResult (MIDI-Modus)',
      () async {
    final session = _buildSession();
    session.setReferenceSource(ReferenceSource.midi);
    session.midiSessionId = 'sess-1';
    session.selectedTrackIndex = 0;
    session.targetCurve = const [TargetPoint(t: 0.0, hz: 440.0, midiNote: 69)];

    await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.wav');

    expect(session.scoreStatus, LoadStatus.ok);
    expect(session.scoreResult, isNotNull);
    expect(session.scoreResult!.notes.length, 1);
    expect(session.scoreResult!.summary.overallScore, closeTo(100.0, 0.001));
  });

  test('align() loest score() im Referenz-Modus mit referenceRawCurve aus', () async {
    final session = _buildSession();
    session.setReferenceSource(ReferenceSource.recording);
    await session.analyzeReference(Uint8List.fromList([9, 9, 9]), 'referenz.wav');

    await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.wav');

    expect(session.scoreStatus, LoadStatus.ok);
    expect(session.scoreResult, isNotNull);
  });

  test('setReferenceSource setzt scoreResult/scoreStatus zurueck', () async {
    final session = _buildSession();
    session.setReferenceSource(ReferenceSource.midi);
    session.midiSessionId = 'sess-1';
    session.selectedTrackIndex = 0;
    session.targetCurve = const [TargetPoint(t: 0.0, hz: 440.0, midiNote: 69)];
    await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.wav');
    expect(session.scoreResult, isNotNull);

    session.setReferenceSource(ReferenceSource.recording);

    expect(session.scoreResult, isNull);
    expect(session.scoreStatus, LoadStatus.idle);
  });

  test('selectTrack setzt scoreResult/scoreStatus zurueck (neue Zielmelodie)', () async {
    final session = _buildSession();
    session.setReferenceSource(ReferenceSource.midi);
    session.midiSessionId = 'sess-1';
    session.selectedTrackIndex = 0;
    session.targetCurve = const [TargetPoint(t: 0.0, hz: 440.0, midiNote: 69)];
    await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.wav');
    expect(session.scoreResult, isNotNull);

    await session.selectTrack(1);

    expect(session.scoreResult, isNull);
    expect(session.scoreStatus, LoadStatus.idle);
  });

  test(
      'score() sendet im Referenz-Modus die TRANSPONIERTE Anzeigekurve, '
      'damit Chart und Bewertung uebereinstimmen', () async {
    final client = _FakeApiClient();
    final session = SessionState(
      midiApi: MidiApi(client),
      audioApi: AudioApi(client),
      syncApi: SyncApi(client),
      scoreApi: ScoreApi(client),
      feedbackApi: FeedbackApi(client),
    );
    session.setReferenceSource(ReferenceSource.recording);
    await session.analyzeReference(Uint8List.fromList([9, 9, 9]), 'referenz.wav');
    // Referenzkurve hat laut _FakeApiClient.postMultipart hz=440.0 fuer den ersten Frame.
    await session.setTranspose(12);

    await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.wav');

    final sentTargetCurve = client.lastPostJsonBody!['target_curve'] as List;
    final firstFrameHz = (sentTargetCurve[0] as Map)['hz'] as num;
    // displayedTargetCurve ist mit +12 Halbtoenen transponiert: 440.0 * 2^(12/12) = 880.0.
    // Wuerde score() faelschlich die unveraenderte referenceRawCurve senden, waere
    // firstFrameHz hier 440.0 statt 880.0.
    expect(firstFrameHz, closeTo(880.0, 0.01));
  });

  test('setTranspose loest im MIDI-Modus nach einem erfolgreichen Alignment ein '
      'erneutes score() aus', () async {
    final session = _buildSession();
    session.setReferenceSource(ReferenceSource.midi);
    session.midiSessionId = 'sess-1';
    session.selectedTrackIndex = 0;
    session.targetCurve = const [TargetPoint(t: 0.0, hz: 440.0, midiNote: 69)];
    await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.wav');
    expect(session.scoreResult, isNotNull);

    // getTrackCurve() ist im Fake nicht abgedeckt (nur postMultipart/postJson), daher
    // schlaegt der Reload selbst fehl - relevant ist hier nur, dass score() danach
    // trotzdem erneut versucht wird (alignedSungCurve ist zu diesem Zeitpunkt noch
    // von der vorherigen Aufnahme befuellt).
    await session.setTranspose(5);

    expect(session.scoreStatus, isNot(LoadStatus.idle));
  });

  test('analyzeAudio speichert den Dateinamen der Gesangsaufnahme', () async {
    final session = _buildSession();
    session.midiSessionId = 'sess-1';
    session.selectedTrackIndex = 0;
    session.targetCurve = const [TargetPoint(t: 0.0, hz: 440.0, midiNote: 69)];

    await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'aufnahme.m4a');

    expect(session.sungAudioFilename, 'aufnahme.m4a');
  });

  test('setReferenceSource setzt sungAudioFilename zurueck, wenn sungAudioBytes zurueckgesetzt wird',
      () async {
    final session = _buildSession();
    session.setReferenceSource(ReferenceSource.midi);
    session.midiSessionId = 'sess-1';
    session.selectedTrackIndex = 0;
    session.targetCurve = const [TargetPoint(t: 0.0, hz: 440.0, midiNote: 69)];
    await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'aufnahme.m4a');
    expect(session.sungAudioFilename, 'aufnahme.m4a');

    session.setReferenceSource(ReferenceSource.recording);

    expect(session.sungAudioFilename, isNull);
  });

  test('requestFeedback() setzt feedbackResult nach erfolgreichem Aufruf', () async {
    final session = _buildSession();
    session.setReferenceSource(ReferenceSource.midi);
    session.midiSessionId = 'sess-1';
    session.selectedTrackIndex = 0;
    await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.wav');
    await session.score();

    await session.requestFeedback();

    expect(session.feedbackStatus, LoadStatus.ok);
    expect(session.feedbackResult, isNotNull);
    expect(session.feedbackResult!.points.first.problem, 'Timing daneben');
  });

  test('requestFeedback() setzt feedbackStatus auf error, wenn der Aufruf fehlschlaegt', () async {
    final client = _FakeApiClient()..throwOnFeedback = ApiException(503, 'Feedback nicht verfuegbar.');
    final session = SessionState(
      midiApi: MidiApi(client),
      audioApi: AudioApi(client),
      syncApi: SyncApi(client),
      scoreApi: ScoreApi(client),
      feedbackApi: FeedbackApi(client),
    );
    session.setReferenceSource(ReferenceSource.midi);
    session.midiSessionId = 'sess-1';
    session.selectedTrackIndex = 0;
    await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.wav');
    await session.score();

    await session.requestFeedback();

    expect(session.feedbackStatus, LoadStatus.error);
    expect(session.feedbackMessage, contains('Feedback nicht verfuegbar'));
  });

  test('requestFeedback() verhindert Doppel-Tap: zwei parallele Aufrufe loesen nur einen HTTP-Call aus', () async {
    final client = _FakeApiClient();
    final session = SessionState(
      midiApi: MidiApi(client),
      audioApi: AudioApi(client),
      syncApi: SyncApi(client),
      scoreApi: ScoreApi(client),
      feedbackApi: FeedbackApi(client),
    );
    session.setReferenceSource(ReferenceSource.midi);
    session.midiSessionId = 'sess-1';
    session.selectedTrackIndex = 0;
    await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.wav');
    await session.score();

    final first = session.requestFeedback();
    final second = session.requestFeedback();
    await Future.wait([first, second]);

    expect(client.feedbackCallCount, 1);
    expect(session.feedbackStatus, LoadStatus.ok);
  });

  test('requestFeedback() ohne scoreResult tut nichts', () async {
    final session = _buildSession();
    await session.requestFeedback();
    expect(session.feedbackStatus, LoadStatus.idle);
  });

  test('ein erneutes score() setzt ein zuvor geholtes feedbackResult zurueck', () async {
    final session = _buildSession();
    session.setReferenceSource(ReferenceSource.midi);
    session.midiSessionId = 'sess-1';
    session.selectedTrackIndex = 0;
    await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.wav');
    await session.score();
    await session.requestFeedback();
    expect(session.feedbackResult, isNotNull);

    await session.score();

    expect(session.feedbackResult, isNull);
    expect(session.feedbackStatus, LoadStatus.idle);
  });

  group('SessionState geteilter Player (play/playFrom/pause/stop)', () {
    test('play() setzt isPlaying nach Abschluss auf true', () async {
      final fake = _FakePlaybackController();
      final session = _buildSessionWithPlayback(fake);
      final bytes = Uint8List.fromList([1, 2, 3]);

      await session.play(bytes);

      expect(session.isPlaying, isTrue);
      expect(fake.playCallCount, 1);
    });

    test('pause() setzt isPlaying nach Abschluss auf false', () async {
      final fake = _FakePlaybackController();
      final session = _buildSessionWithPlayback(fake);
      await session.play(Uint8List.fromList([1, 2, 3]));
      expect(session.isPlaying, isTrue);

      await session.pause();

      expect(session.isPlaying, isFalse);
      expect(fake.pauseCallCount, 1);
    });

    test(
        'Generation-Guard: eine erst spaeter aufloesende play()-Zusage darf einen '
        'zwischenzeitlich per stop() gesetzten Zustand nicht mehr rueckwirkend '
        'ueberschreiben (Ausloese-Reihenfolge zaehlt, nicht Abschluss-Reihenfolge)',
        () async {
      final fake = _FakePlaybackController()..playCompleter = Completer<void>();
      final session = _buildSessionWithPlayback(fake);
      final bytesA = Uint8List.fromList([1, 2, 3]);

      // play() wird ausgeloest, haengt aber in fake.play() fest (Completer offen).
      final firstCall = session.play(bytesA);

      // stop() wird SPAETER ausgeloest, loest aber SCHNELLER auf (kein Completer).
      await session.stop();
      expect(session.isPlaying, isFalse);
      expect(session.isPlayingAudio(bytesA), isFalse);
      expect(fake.stopCallCount, 1);

      // Jetzt loest die veraltete play()-Zusage nachtraeglich auf.
      fake.playCompleter!.complete();
      await firstCall;

      // Der Generation-Guard muss verhindern, dass die veraltete play()-Ausloesung
      // den durch das spaeter ausgeloeste (aber frueher fertige) stop() gesetzten
      // Zustand rueckwirkend ueberschreibt.
      expect(session.isPlaying, isFalse);
      expect(session.isPlayingAudio(bytesA), isFalse);
    });

    test('isPlayingAudio prueft Objekt-Identitaet, nicht Byteinhalt', () async {
      final fake = _FakePlaybackController();
      final session = _buildSessionWithPlayback(fake);
      final bytesA = Uint8List.fromList([1, 2, 3]);
      final bytesASameContent = Uint8List.fromList([1, 2, 3]);

      await session.play(bytesA);

      expect(session.isPlayingAudio(bytesA), isTrue);
      expect(session.isPlayingAudio(bytesASameContent), isFalse);
      expect(session.isPlayingAudio(null), isFalse);
    });

    test(
        'setReferenceSource() stoppt eine laufende Wiedergabe des geteilten Players '
        '(sonst spielt sie nach dem Wechsel unsichtbar unbegrenzt weiter, Regression)',
        () async {
      final fake = _FakePlaybackController();
      final session = _buildSessionWithPlayback(fake);
      session.setReferenceSource(ReferenceSource.midi);
      await session.play(Uint8List.fromList([1, 2, 3]));
      expect(session.isPlaying, isTrue);

      session.setReferenceSource(ReferenceSource.recording);
      await Future<void>.delayed(Duration.zero);

      expect(fake.stopCallCount, 1);
      expect(session.isPlaying, isFalse);
    });

    test(
        'uploadMidi() stoppt eine laufende Wiedergabe des geteilten Players '
        '(sonst spielt eine Track-Vorschau nach dem Cache-Clear unsichtbar unbegrenzt '
        'weiter, Regression)', () async {
      final fake = _FakePlaybackController();
      final session = _buildSessionWithPlayback(fake);
      await session.play(Uint8List.fromList([1, 2, 3]));
      expect(session.isPlaying, isTrue);

      await session.uploadMidi(Uint8List.fromList([9, 9, 9]), 'song.mid');

      expect(fake.stopCallCount, 1);
      expect(session.isPlaying, isFalse);
    });

    test('positionFor/durationFor liefern Duration.zero fuer Bytes, die nicht _playingBytes sind',
        () async {
      final fake = _FakePlaybackController();
      final session = _buildSessionWithPlayback(fake);
      final bytes = Uint8List.fromList([1, 2, 3]);
      final otherBytes = Uint8List.fromList([4, 5, 6]);

      await session.play(bytes);

      expect(session.positionFor(otherBytes), Duration.zero);
      expect(session.durationFor(otherBytes), Duration.zero);
      expect(session.positionFor(null), Duration.zero);
      expect(session.durationFor(null), Duration.zero);
    });

    test('ein Positions-/Dauer-Tick des Fake-Controllers erscheint in positionFor/durationFor',
        () async {
      final fake = _FakePlaybackController();
      final session = _buildSessionWithPlayback(fake);
      final bytes = Uint8List.fromList([1, 2, 3]);

      await session.play(bytes);
      fake._positionChangedController.add(const Duration(seconds: 2));
      fake._durationChangedController.add(const Duration(seconds: 10));
      // Stream-Events laufen als Microtask - kurz nachgeben, bevor gelesen wird.
      await Future<void>.delayed(Duration.zero);

      expect(session.positionFor(bytes), const Duration(seconds: 2));
      expect(session.durationFor(bytes), const Duration(seconds: 10));
    });

    test(
        'Trackwechsel setzt positionFor/durationFor fuer die alte Spur synchron sofort '
        'auf Duration.zero zurueck, noch bevor ein neuer Tick fuer die neue Spur eintrifft',
        () async {
      final fake = _FakePlaybackController();
      final session = _buildSessionWithPlayback(fake);
      final bytes = Uint8List.fromList([1, 2, 3]);
      final otherBytes = Uint8List.fromList([4, 5, 6]);

      await session.play(bytes);
      fake._positionChangedController.add(const Duration(seconds: 2));
      fake._durationChangedController.add(const Duration(seconds: 10));
      await Future<void>.delayed(Duration.zero);
      expect(session.positionFor(bytes), const Duration(seconds: 2));

      // play() fuer eine neue Spur haengt in fake.play() fest (Completer offen) -
      // der Reset muss trotzdem schon VOR dem Abschluss des await sichtbar sein.
      fake.playCompleter = Completer<void>();
      final secondCall = session.play(otherBytes);

      expect(session.positionFor(bytes), Duration.zero);
      expect(session.durationFor(bytes), Duration.zero);
      expect(session.positionFor(otherBytes), Duration.zero);

      fake.playCompleter!.complete();
      await secondCall;
    });

    test(
        'Bloßes Erzeugen einer SessionState und Abonnieren von onPositionChanged baut den '
        'lazy Player nicht (Regressionsschutz fuer die Lazy-Invariante)', () {
      var buildCount = 0;
      final client = _FakeApiClient();
      final session = SessionState(
        midiApi: MidiApi(client),
        audioApi: AudioApi(client),
        syncApi: SyncApi(client),
        scoreApi: ScoreApi(client),
        feedbackApi: FeedbackApi(client),
        playbackControllerFactory: () {
          buildCount++;
          return _FakePlaybackController();
        },
      );

      final sub = session.onPositionChanged.listen((_) {});
      final sub2 = session.onDurationChanged.listen((_) {});

      expect(buildCount, 0);
      sub.cancel();
      sub2.cancel();
    });

    test('dispose() wirft nicht und raeumt die Positions-/Dauer-Subscriptions und -Controller auf',
        () async {
      final fake = _FakePlaybackController();
      final session = _buildSessionWithPlayback(fake);
      await session.play(Uint8List.fromList([1, 2, 3]));

      expect(() => session.dispose(), returnsNormally);
    });
  });

  group('SessionState Spur-Vorschau (previewBytesForTrack)', () {
    test('erster Aufruf holt Bytes ueber die API und cacht sie', () async {
      final client = _FakeApiClient();
      final session = SessionState(
        midiApi: MidiApi(client),
        audioApi: AudioApi(client),
        syncApi: SyncApi(client),
        scoreApi: ScoreApi(client),
        feedbackApi: FeedbackApi(client),
      );
      session.midiSessionId = 'session-1';

      final bytes = await session.previewBytesForTrack(0);

      expect(bytes, isNotEmpty);
      expect(client.getBytesCallCount, 1);
      expect(session.cachedPreviewBytes(0), same(bytes));
    });

    test('zweiter Aufruf fuer denselben Track nutzt den Cache statt erneut zu laden', () async {
      final client = _FakeApiClient();
      final session = SessionState(
        midiApi: MidiApi(client),
        audioApi: AudioApi(client),
        syncApi: SyncApi(client),
        scoreApi: ScoreApi(client),
        feedbackApi: FeedbackApi(client),
      );
      session.midiSessionId = 'session-1';

      await session.previewBytesForTrack(2);
      await session.previewBytesForTrack(2);

      expect(client.getBytesCallCount, 1);
    });

    test('uploadMidi() leert den Preview-Cache', () async {
      final client = _FakeApiClient();
      final session = SessionState(
        midiApi: MidiApi(client),
        audioApi: AudioApi(client),
        syncApi: SyncApi(client),
        scoreApi: ScoreApi(client),
        feedbackApi: FeedbackApi(client),
      );
      session.midiSessionId = 'session-1';
      await session.previewBytesForTrack(0);
      expect(session.cachedPreviewBytes(0), isNotNull);

      await session.uploadMidi(Uint8List.fromList([9, 9, 9]), 'song.mid');

      expect(session.cachedPreviewBytes(0), isNull);
    });
  });

  group('SessionState Aufnahme-Kuerzung', () {
    test('formatDurationMinSec formatiert Sekunden als m:ss', () {
      expect(formatDurationMinSec(0.0), '0:00');
      expect(formatDurationMinSec(59.0), '0:59');
      expect(formatDurationMinSec(60.0), '1:00');
      expect(formatDurationMinSec(116.0), '1:56');
    });

    test('analyzeAudio() setzt audioTruncated und die Warnmeldung, wenn gekuerzt wurde', () async {
      final client = _TruncatingFakeApiClient();
      final session = SessionState(
        midiApi: MidiApi(client),
        audioApi: AudioApi(client),
        syncApi: SyncApi(client),
        scoreApi: ScoreApi(client),
        feedbackApi: FeedbackApi(client),
      );

      await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.m4a');

      expect(session.audioTruncated, isTrue);
      expect(session.audioStatus, LoadStatus.warning);
      // '1:56' ist die urspruengliche (Vor-Kuerzungs-)Dauer, '1:30' die Dauer, auf
      // die tatsaechlich gekuerzt wurde (aus dem letzten Kurvenpunkt abgeleitet -
      // siehe result.curve.last.t in analyzeAudio()).
      expect(session.audioMessage, contains('1:56'));
      expect(session.audioMessage, contains('1:30'));
    });

    test('analyzeAudio() setzt audioTruncated NICHT, wenn nicht gekuerzt wurde', () async {
      final client = _FakeApiClient();
      final session = SessionState(
        midiApi: MidiApi(client),
        audioApi: AudioApi(client),
        syncApi: SyncApi(client),
        scoreApi: ScoreApi(client),
        feedbackApi: FeedbackApi(client),
      );

      await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.m4a');

      expect(session.audioTruncated, isFalse);
      expect(session.audioStatus, LoadStatus.ok);
    });
  });

  group('SessionState Toleranz-Preset', () {
    test('tolerancePreset startet mit TolerancePreset.normal', () {
      final session = _buildSession();
      expect(session.tolerancePreset, TolerancePreset.normal);
    });

    test('setTolerancePreset loest bei vorhandenem Score ein erneutes score() '
        'aus und sendet das Preset mit', () async {
      final client = _FakeApiClient();
      final session = SessionState(
        midiApi: MidiApi(client),
        audioApi: AudioApi(client),
        syncApi: SyncApi(client),
        scoreApi: ScoreApi(client),
        feedbackApi: FeedbackApi(client),
      );
      session.setReferenceSource(ReferenceSource.midi);
      session.midiSessionId = 'sess-1';
      session.selectedTrackIndex = 0;
      session.targetCurve = const [TargetPoint(t: 0.0, hz: 440.0, midiNote: 69)];
      await session.analyzeAudio(Uint8List.fromList([1, 2, 3]), 'gesang.wav');
      expect(session.scoreResult, isNotNull);

      await session.setTolerancePreset(TolerancePreset.strict);

      expect(session.tolerancePreset, TolerancePreset.strict);
      expect(client.lastPostJsonBody?['tolerance_preset'], 'strict');
    });

    test('setTolerancePreset persistiert das Preset, eine neue SessionState-Instanz '
        'laedt es per loadPersistedTolerancePreset() zurueck', () async {
      final sessionA = _buildSession();
      await sessionA.setTolerancePreset(TolerancePreset.loose);

      final sessionB = _buildSession();
      expect(sessionB.tolerancePreset, TolerancePreset.normal,
          reason: 'vor dem Laden noch der Default');
      await sessionB.loadPersistedTolerancePreset();

      expect(sessionB.tolerancePreset, TolerancePreset.loose);
    });

    test('loadPersistedTolerancePreset() aendert nichts, wenn nie etwas '
        'gespeichert wurde', () async {
      SharedPreferences.setMockInitialValues({});
      final session = _buildSession();

      await session.loadPersistedTolerancePreset();

      expect(session.tolerancePreset, TolerancePreset.normal);
    });
  });
}
