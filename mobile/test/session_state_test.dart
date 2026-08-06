import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:singing_feedback_mobile/api/api_client.dart';
import 'package:singing_feedback_mobile/api/audio_api.dart';
import 'package:singing_feedback_mobile/api/midi_api.dart';
import 'package:singing_feedback_mobile/api/sync_api.dart';
import 'package:singing_feedback_mobile/models/target_point.dart';
import 'package:singing_feedback_mobile/state/session_state.dart';

class _FakeApiClient extends ApiClient {
  _FakeApiClient() : super(baseUrl: 'http://fake.local');

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
    };
  }
}

SessionState _buildSession() {
  final client = _FakeApiClient();
  return SessionState(
    midiApi: MidiApi(client),
    audioApi: AudioApi(client),
    syncApi: SyncApi(client),
  );
}

void main() {
  test('displayedTargetCurve liefert im MIDI-Modus targetCurve unveraendert', () {
    final session = _buildSession();
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
}
