import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:singing_feedback_mobile/api/api_client.dart';
import 'package:singing_feedback_mobile/api/audio_api.dart';
import 'package:singing_feedback_mobile/api/feedback_api.dart';
import 'package:singing_feedback_mobile/api/midi_api.dart';
import 'package:singing_feedback_mobile/api/score_api.dart';
import 'package:singing_feedback_mobile/api/sync_api.dart';
import 'package:singing_feedback_mobile/state/session_state.dart';
import 'package:singing_feedback_mobile/widgets/playback_seekbar.dart';

/// Fake-Implementierung von [AudioPlaybackController] fuer Tests, ganz ohne
/// echten Plattform-Kanal - gleiches Muster wie in playback_button_test.dart/
/// session_state_test.dart. [playFrom] kann ueber [playFromCompleter] auf
/// "haengend" gehalten werden, um den Doppel-Seek-Generation-Guard zu testen;
/// jeder Aufruf wird zusaetzlich (Bytes, Position) in [playFromCalls]
/// protokolliert, damit die Reihenfolge unabhaengig vom Abschluss der Awaits
/// ueberprueft werden kann.
class _FakePlaybackController implements AudioPlaybackController {
  Completer<void>? playFromCompleter;
  Object? throwOnPlayFrom;
  int playFromCallCount = 0;
  final List<(Uint8List, Duration)> playFromCalls = [];
  final _completeController = StreamController<void>.broadcast();
  final _positionChangedController = StreamController<Duration>.broadcast();
  final _durationChangedController = StreamController<Duration>.broadcast();

  @override
  Future<void> play(Uint8List bytes) async {}

  @override
  Future<void> playFrom(Uint8List bytes, Duration position) async {
    playFromCallCount++;
    playFromCalls.add((bytes, position));
    if (playFromCompleter != null) {
      await playFromCompleter!.future;
    }
    if (throwOnPlayFrom != null) throw throwOnPlayFrom!;
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

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

SessionState _buildSession(AudioPlaybackController fake) {
  final client = ApiClient(baseUrl: 'http://fake.local');
  return SessionState(
    midiApi: MidiApi(client),
    audioApi: AudioApi(client),
    syncApi: SyncApi(client),
    scoreApi: ScoreApi(client),
    feedbackApi: FeedbackApi(client),
    playbackControllerFactory: () => fake,
  );
}

Widget _wrap(SessionState session, Widget child) {
  return ChangeNotifierProvider<SessionState>.value(
    value: session,
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

void main() {
  group('PlaybackSeekbar', () {
    testWidgets('rendert nichts, wenn audioBytes null ist', (tester) async {
      final fake = _FakePlaybackController();
      final session = _buildSession(fake);

      await tester
          .pumpWidget(_wrap(session, const PlaybackSeekbar(audioBytes: null)));

      expect(find.byType(Slider), findsNothing);
      expect(find.byType(PlaybackSeekbar), findsOneWidget);
    });

    testWidgets(
        'ohne Dauer-Tick ist der Slider deaktiviert und beide Labels zeigen 0:00',
        (tester) async {
      final fake = _FakePlaybackController();
      final session = _buildSession(fake);
      final bytes = Uint8List.fromList([1, 2, 3]);

      await tester
          .pumpWidget(_wrap(session, PlaybackSeekbar(audioBytes: bytes)));

      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.onChanged, isNull);
      expect(slider.onChangeEnd, isNull);
      expect(slider.max, 1);
      expect(slider.value, 0);
      expect(find.text('0:00'), findsNWidgets(2));
    });

    testWidgets(
        'ein Dauer-Tick aktualisiert Max-Wert und Dauer-Label auch ohne Positions-Tick',
        (tester) async {
      final fake = _FakePlaybackController();
      final session = _buildSession(fake);
      final bytes = Uint8List.fromList([1, 2, 3]);

      await tester
          .pumpWidget(_wrap(session, PlaybackSeekbar(audioBytes: bytes)));

      await session.play(bytes);
      await tester.pump();
      fake._durationChangedController.add(const Duration(seconds: 125));
      await tester.pump();
      await tester.pump();

      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.max, 125.0);
      expect(slider.onChanged, isNotNull);
      expect(find.text('2:05'), findsOneWidget);
      // Position blieb bei 0:00, da noch kein Positions-Tick eintraf.
      expect(find.text('0:00'), findsOneWidget);
    });

    testWidgets(
        'ein Positions-Tick ist nur fuer die tatsaechlich abgespielten Bytes sichtbar; '
        'die jeweils andere Bytes-Identitaet bleibt bei 0:00', (tester) async {
      final fake = _FakePlaybackController();
      final session = _buildSession(fake);
      final bytesA = Uint8List.fromList([1, 2, 3]);
      final bytesB = Uint8List.fromList([4, 5, 6]);

      await tester.pumpWidget(_wrap(
        session,
        Column(children: [
          PlaybackSeekbar(audioBytes: bytesA),
          PlaybackSeekbar(audioBytes: bytesB),
        ]),
      ));

      await session.play(bytesA);
      await tester.pump();
      fake._durationChangedController.add(const Duration(seconds: 100));
      fake._positionChangedController.add(const Duration(seconds: 40));
      await tester.pump();
      await tester.pump();

      // bytesA spielt: Position 0:40 sichtbar.
      expect(find.text('0:40'), findsOneWidget);
      // bytesB spielt nicht: bleibt bei 0:00/0:00, unabhaengig vom Tick.
      final sliders = tester.widgetList<Slider>(find.byType(Slider)).toList();
      expect(
          sliders[1].max, 1); // zweiter Seekbar (bytesB) weiterhin ohne Dauer
      expect(sliders[1].value, 0);
    });

    testWidgets(
        'Drag-End auf dem Slider loest playFrom mit den erwarteten audioBytes und der '
        'passenden Duration aus', (tester) async {
      final fake = _FakePlaybackController();
      final session = _buildSession(fake);
      final bytes = Uint8List.fromList([1, 2, 3]);

      await tester
          .pumpWidget(_wrap(session, PlaybackSeekbar(audioBytes: bytes)));

      await session.play(bytes);
      await tester.pump();
      fake._durationChangedController.add(const Duration(seconds: 200));
      await tester.pump();
      await tester.pump();

      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.onChangeEnd, isNotNull);
      slider.onChangeEnd!(42.0);
      await tester.pump();
      await tester.pump();

      expect(fake.playFromCallCount, 1);
      expect(identical(fake.playFromCalls.single.$1, bytes), isTrue);
      expect(fake.playFromCalls.single.$2, const Duration(milliseconds: 42000));
    });

    testWidgets(
        'schneller Doppel-Seek: beide onChangeEnd-Aufrufe erreichen playFrom, der '
        'zweite (neuere) gewinnt via SessionState._playbackGeneration',
        (tester) async {
      final fake = _FakePlaybackController();
      final session = _buildSession(fake);
      final bytes = Uint8List.fromList([1, 2, 3]);

      await tester
          .pumpWidget(_wrap(session, PlaybackSeekbar(audioBytes: bytes)));

      await session.play(bytes);
      await tester.pump();
      fake._durationChangedController.add(const Duration(seconds: 200));
      await tester.pump();
      await tester.pump();

      fake.playFromCompleter = Completer<void>();
      final slider = tester.widget<Slider>(find.byType(Slider));
      slider.onChangeEnd!(10.0);
      slider.onChangeEnd!(90.0);

      expect(fake.playFromCallCount, 2);
      expect(fake.playFromCalls[0].$2, const Duration(milliseconds: 10000));
      expect(fake.playFromCalls[1].$2, const Duration(milliseconds: 90000));

      fake.playFromCompleter!.complete();
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(session.isPlayingAudio(bytes), isTrue);
    });

    testWidgets(
        'didUpdateWidget mitten im Drag setzt _dragValue/Fehlertext zurueck - kein '
        'stale Seek gegen die alten Bytes, kein stale Drag-Wert und keine stale '
        'Fehlermeldung sichtbar, sobald die neue Spur tatsaechlich Dauer hat',
        (tester) async {
      final fake = _FakePlaybackController();
      final session = _buildSession(fake);
      final bytesOld = Uint8List.fromList([1, 2, 3]);
      final bytesNew = Uint8List.fromList([4, 5, 6]);

      await tester
          .pumpWidget(_wrap(session, PlaybackSeekbar(audioBytes: bytesOld)));

      await session.play(bytesOld);
      await tester.pump();
      fake._durationChangedController.add(const Duration(seconds: 100));
      await tester.pump();
      await tester.pump();

      // Erst einen fehlschlagenden Seek gegen die ALTEN Bytes ausloesen, damit
      // _errorMessage gesetzt ist - dieser Zweig von didUpdateWidget (Fehlertext-
      // Reset) hatte bislang keinen eigenen Test.
      fake.throwOnPlayFrom = Exception('Geraetefehler');
      var slider = tester.widget<Slider>(find.byType(Slider));
      slider.onChangeEnd!(20.0);
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Sprung fehlgeschlagen'), findsOneWidget);
      fake.throwOnPlayFrom = null;

      // Aktiver Drag: nur lokaler State, kein weiterer playFrom-Aufruf.
      slider = tester.widget<Slider>(find.byType(Slider));
      slider.onChanged!(30.0);
      await tester.pump();
      expect(find.text('0:30'), findsOneWidget);
      final playFromCallsBeforeSwap = fake.playFromCallCount;

      // Bytes wechseln waehrend des Drags (z.B. Elternwidget springt zu anderer Spur).
      await tester
          .pumpWidget(_wrap(session, PlaybackSeekbar(audioBytes: bytesNew)));
      await tester.pump();

      // Kein weiterer Seek wurde ausgeloest (kein stale Seek gegen die alten Bytes).
      expect(fake.playFromCallCount, playFromCallsBeforeSwap);
      // Die stale Fehlermeldung von den alten Bytes darf nicht mehr sichtbar sein.
      expect(find.textContaining('Sprung fehlgeschlagen'), findsNothing);

      // Die neuen Bytes jetzt TATSAECHLICH abspielen + einen Dauer-Tick liefern,
      // damit hasDuration==true wird. Ohne das wuerde der Slider allein durch den
      // disabled-Zweig (hasDuration==false -> value fest 0) auf 0 stehen, selbst
      // wenn _dragValue nie zurueckgesetzt worden waere - der Test wuerde dann
      // "gruen" bleiben, auch wenn der Reset in didUpdateWidget entfernt wuerde.
      // Erst so spiegelt der angezeigte Wert wirklich den internen _dragValue-
      // Zustand (bzw. dessen Abwesenheit) wider.
      await session.play(bytesNew);
      await tester.pump();
      fake._durationChangedController.add(const Duration(seconds: 50));
      await tester.pump();
      await tester.pump();

      final newSlider = tester.widget<Slider>(find.byType(Slider));
      expect(newSlider.onChanged, isNotNull);
      expect(newSlider.max, 50.0);
      // Kein stale Drag-Wert (0:30 von den alten Bytes) leckt durch - Position ist
      // frisch 0:00 fuer die neue, gerade erst gestartete Spur.
      expect(newSlider.value, 0);
      expect(find.text('0:00'), findsOneWidget);
    });

    testWidgets(
        'Trackwechsel-Handoff zwischen zwei gleichzeitig montierten Seekbars: play() auf '
        'die Gesangsspur setzt die zuvor live laufende Referenz-Seekbar synchron zurueck '
        'auf disabled/0:00 (Ganzbranch-Review-Luecke - Einzeltests deckten je nur eine '
        'Bar isoliert ab, nie den tatsaechlichen Handoff zwischen zwei montierten Bars)',
        (tester) async {
      final fake = _FakePlaybackController();
      final session = _buildSession(fake);
      final referenceBytes = Uint8List.fromList([1, 2, 3]);
      final sungBytes = Uint8List.fromList([4, 5, 6]);

      await tester.pumpWidget(_wrap(
        session,
        Column(children: [
          PlaybackSeekbar(audioBytes: referenceBytes),
          PlaybackSeekbar(audioBytes: sungBytes),
        ]),
      ));

      await session.play(referenceBytes);
      await tester.pump();
      fake._durationChangedController.add(const Duration(seconds: 100));
      fake._positionChangedController.add(const Duration(seconds: 40));
      await tester.pump();
      await tester.pump();

      var sliders = tester.widgetList<Slider>(find.byType(Slider)).toList();
      expect(sliders[0].max, 100.0);
      expect(sliders[0].value, 40.0);
      expect(sliders[0].onChanged, isNotNull);
      expect(find.text('0:40'), findsOneWidget);

      // Jetzt auf die Gesangsspur wechseln - die Referenz-Bar ist nicht mehr
      // die abgespielte Spur.
      await session.play(sungBytes);
      await tester.pump();
      await tester.pump();

      sliders = tester.widgetList<Slider>(find.byType(Slider)).toList();
      expect(sliders[0].max, 1);
      expect(sliders[0].value, 0);
      expect(sliders[0].onChanged, isNull);
      // Beide Bars zeigen jetzt 0:00/0:00 (Referenz zurueckgesetzt, Gesang noch
      // ohne Tick) - macht 4 Vorkommen von "0:00" ueber beide Bars hinweg.
      expect(find.text('0:00'), findsNWidgets(4));
    });

    testWidgets(
        'stop() setzt die Seekbar zurueck auf disabled/0:00 (analog zu setReferenceSource()/'
        'uploadMidi(), die beide stop() im geteilten Player aufrufen)',
        (tester) async {
      final fake = _FakePlaybackController();
      final session = _buildSession(fake);
      final bytes = Uint8List.fromList([1, 2, 3]);

      await tester
          .pumpWidget(_wrap(session, PlaybackSeekbar(audioBytes: bytes)));

      await session.play(bytes);
      await tester.pump();
      fake._durationChangedController.add(const Duration(seconds: 80));
      fake._positionChangedController.add(const Duration(seconds: 20));
      await tester.pump();
      await tester.pump();

      var slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.max, 80.0);
      expect(slider.value, 20.0);

      await session.stop();
      await tester.pump();
      await tester.pump();

      slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.max, 1);
      expect(slider.value, 0);
      expect(slider.onChanged, isNull);
      expect(find.text('0:00'), findsNWidgets(2));
    });

    testWidgets(
        'nach onChangeEnd zeigt die Seekbar sofort das Seek-Ziel, noch bevor irgendein '
        'Stream-Tick eintrifft oder playFrom() zurueckkehrt (pinnt Finding 1: '
        'SessionState.playFrom setzt _lastKnownPosition jetzt synchron optimistisch auf '
        'das Seek-Ziel - vorher blitzte die Bar fuer 100-300ms zurueck auf die ALTE '
        'Position, weil _dragValue schon zurueckgesetzt war, bevor der erste echte '
        'Positions-Tick eintraf)', (tester) async {
      final fake = _FakePlaybackController();
      final session = _buildSession(fake);
      final bytes = Uint8List.fromList([1, 2, 3]);

      await tester
          .pumpWidget(_wrap(session, PlaybackSeekbar(audioBytes: bytes)));

      await session.play(bytes);
      await tester.pump();
      fake._durationChangedController.add(const Duration(seconds: 200));
      fake._positionChangedController.add(const Duration(seconds: 10));
      await tester.pump();
      await tester.pump();

      expect(find.text('0:10'), findsOneWidget);

      // playFrom() haengt fest (Completer offen) - weder loest es auf, noch
      // trifft irgendein neuer Stream-Tick ein.
      fake.playFromCompleter = Completer<void>();
      final slider = tester.widget<Slider>(find.byType(Slider));
      slider.onChangeEnd!(150.0);
      await tester.pump();
      await tester.pump();

      // Die alte Position (0:10) darf nicht mehr sichtbar sein - stattdessen
      // sofort das Seek-Ziel (150s = 2:30), obwohl playFrom() noch haengt und
      // kein einziger Tick eintraf.
      expect(find.text('0:10'), findsNothing);
      expect(find.text('2:30'), findsOneWidget);

      fake.playFromCompleter!.complete();
      await tester.pump();
      await tester.pump();
    });
  });
}
