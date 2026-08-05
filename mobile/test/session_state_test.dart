import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:singing_feedback_mobile/api/api_client.dart';
import 'package:singing_feedback_mobile/api/audio_api.dart';
import 'package:singing_feedback_mobile/api/midi_api.dart';
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
  }) async {
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
  return SessionState(midiApi: MidiApi(client), audioApi: AudioApi(client));
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

    expect(session.transposeSemitones, 12);
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
}
