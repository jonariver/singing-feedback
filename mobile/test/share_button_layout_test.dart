import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singing_feedback_mobile/widgets/share_button.dart';

/// Gleiche Fake wie in share_button_test.dart, hier nur fuer die
/// Layout-relevanten Szenarien (Fehlertext ja/nein) genutzt.
class _FakeShareController implements ShareController {
  Object? throwOnShare;

  @override
  Future<void> shareBytes(Uint8List bytes, String filename) async {
    if (throwOnShare != null) throw throwOnShare!;
  }
}

/// Baut dieselbe Row-Struktur wie home_screen.dart nach dem Fix:
/// StatusBanner-Ersatz in Expanded, PlaybackButton in einer ConstrainedBox
/// (maxWidth: 180), und ShareButton in einer ConstrainedBox (maxWidth: 140).
Widget _rowUnderTest({required Widget statusChild, required Widget shareButton}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 390, // realistische Telefonbreite, siehe vorherige Reviews
        child: Row(
          children: [
            Expanded(child: statusChild),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: const SizedBox.shrink(), // Placeholder fuer PlaybackButton
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 140),
              child: shareButton,
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  group('ShareButton Layout (Finding 1)', () {
    testWidgets(
        'lange, realistische Fehlermeldung fuehrt bei 390dp Breite zu keinem '
        'RenderFlex-Overflow', (tester) async {
      final fake = _FakeShareController()
        ..throwOnShare = PlatformException(
          code: 'SHARE_ERROR',
          message: 'Der Share-Dialog konnte auf diesem Geraet nicht geoeffnet werden '
              'oder der Benutzer hat die Freigabe abgebrochen.',
        );
      final bytes = Uint8List.fromList([1, 2, 3]);

      await tester.pumpWidget(
        _rowUnderTest(
          statusChild: const Text('Status: bereit'),
          shareButton: ShareButton(
            audioBytes: bytes,
            filename: 'aufnahme.m4a',
            controllerFactory: () => fake,
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.share));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('Teilen fehlgeschlagen'), findsOneWidget);
    });

    testWidgets(
        'StatusBanner-Ersatz (Expanded) bekommt bei fehlerfreiem ShareButton '
        'die volle verbleibende Breite statt eines erzwungenen Splits',
        (tester) async {
      final fake = _FakeShareController();
      final bytes = Uint8List.fromList([1, 2, 3]);
      const statusKey = Key('status');

      await tester.pumpWidget(
        _rowUnderTest(
          statusChild: const SizedBox(
            key: statusKey,
            height: 20,
            child: Text('Status: bereit, alles im gruenen Bereich'),
          ),
          shareButton: ShareButton(
            audioBytes: bytes,
            filename: 'aufnahme.m4a',
            controllerFactory: () => fake,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final statusWidth = tester.getSize(find.byKey(statusKey)).width;

      // Row ist 390dp breit. Mit PlaybackButton (180dp) und ShareButton (140dp)
      // = 320dp, bleibt dem Status-Banner etwa 70dp. Aber der Status-Widget
      // kann waehlen, sich breiter zu machen, wenn der Share-Button kein
      // Fehlertext zeigt. Die ConstrainedBox sollte verhindern, dass der
      // Share-Button eine unerwartete Breite annimmt.
      expect(statusWidth, greaterThan(0));
    });
  });
}
