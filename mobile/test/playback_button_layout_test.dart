import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singing_feedback_mobile/widgets/playback_button.dart';

/// Gleiche Fake wie in playback_button_test.dart, hier nur fuer die
/// Layout-relevanten Szenarien (Fehlertext ja/nein) genutzt.
class _FakePlaybackController implements AudioPlaybackController {
  Object? throwOnPlay;

  @override
  Future<void> play(Uint8List bytes) async {
    if (throwOnPlay != null) throw throwOnPlay!;
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Stream<void> get onComplete => const Stream.empty();

  @override
  void dispose() {}
}

/// Baut dieselbe Row-Struktur wie home_screen.dart nach dem Fix fuer Finding 2:
/// StatusBanner-Ersatz in Expanded, PlaybackButton in einer ConstrainedBox
/// (maxWidth: 180) statt in einem gleichwertigen Flexible.
Widget _rowUnderTest({required Widget statusChild, required Widget playbackButton}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 390, // realistische Telefonbreite, siehe vorherige Reviews
        child: Row(
          children: [
            Expanded(child: statusChild),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: playbackButton,
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  group('PlaybackButton Layout (Finding 2)', () {
    testWidgets(
        'lange, realistische Fehlermeldung fuehrt bei 390dp Breite zu keinem '
        'RenderFlex-Overflow', (tester) async {
      final fake = _FakePlaybackController()
        ..throwOnPlay = Exception(
          'Der Audio-Codec wird auf diesem Geraet nicht unterstuetzt und die '
          'Wiedergabe konnte nicht gestartet werden.',
        );
      final bytes = Uint8List.fromList([1, 2, 3]);

      await tester.pumpWidget(
        _rowUnderTest(
          statusChild: const Text('Status: bereit'),
          playbackButton: PlaybackButton(audioBytes: bytes, controllerFactory: () => fake),
        ),
      );

      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('Wiedergabe fehlgeschlagen'), findsOneWidget);
    });

    testWidgets(
        'StatusBanner-Ersatz (Expanded) bekommt bei fehlerfreiem PlaybackButton '
        'die volle verbleibende Breite statt eines erzwungenen 50/50-Splits',
        (tester) async {
      final fake = _FakePlaybackController();
      final bytes = Uint8List.fromList([1, 2, 3]);
      const statusKey = Key('status');

      await tester.pumpWidget(
        _rowUnderTest(
          statusChild: const SizedBox(
            key: statusKey,
            height: 20,
            child: Text('Status: bereit, alles im gruenen Bereich'),
          ),
          playbackButton: PlaybackButton(audioBytes: bytes, controllerFactory: () => fake),
        ),
      );
      await tester.pumpAndSettle();

      final statusWidth = tester.getSize(find.byKey(statusKey)).width;

      // Row ist 390dp breit. Ein erzwungener 50/50-Split (altes Flexible-
      // Verhalten) haette dem Status-Widget nur ~195dp gegeben. Ohne Fehlertext
      // braucht der PlaybackButton nur die Breite seines IconButtons (~48dp),
      // der Rest muss beim Expanded-Geschwister landen.
      expect(statusWidth, greaterThan(300));
    });
  });
}
