import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singing_feedback_mobile/widgets/share_button.dart';

/// Fake-Implementierung von [ShareController] fuer Tests, ganz ohne echten
/// Plattform-Kanal - analog zu _FakePlaybackController in playback_button_test.dart.
class _FakeShareController implements ShareController {
  Completer<void>? shareCompleter;
  Object? throwOnShare;
  int shareCallCount = 0;
  Uint8List? lastBytes;
  String? lastFilename;

  @override
  Future<void> shareBytes(Uint8List bytes, String filename) async {
    shareCallCount++;
    lastBytes = bytes;
    lastFilename = filename;
    if (shareCompleter != null) {
      await shareCompleter!.future;
    }
    if (throwOnShare != null) throw throwOnShare!;
  }
}

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('ShareButton', () {
    testWidgets('rendert nichts ohne audioBytes/filename', (tester) async {
      await tester.pumpWidget(
        _wrap(ShareButton(audioBytes: null, filename: null)),
      );

      expect(find.byIcon(Icons.share), findsNothing);
    });

    testWidgets('Tap loest shareBytes mit den richtigen Bytes/Dateinamen aus', (tester) async {
      final fake = _FakeShareController();
      final bytes = Uint8List.fromList([1, 2, 3]);

      await tester.pumpWidget(
        _wrap(ShareButton(
          audioBytes: bytes,
          filename: 'aufnahme.m4a',
          controllerFactory: () => fake,
        )),
      );

      await tester.tap(find.byIcon(Icons.share));
      await tester.pumpAndSettle();

      expect(fake.shareCallCount, 1);
      expect(fake.lastBytes, bytes);
      expect(fake.lastFilename, 'aufnahme.m4a');
    });

    testWidgets(
        'Busy-Guard verhindert einen zweiten Share-Aufruf, waehrend der erste noch laeuft',
        (tester) async {
      final fake = _FakeShareController()..shareCompleter = Completer<void>();
      final bytes = Uint8List.fromList([1, 2, 3]);

      await tester.pumpWidget(
        _wrap(ShareButton(
          audioBytes: bytes,
          filename: 'aufnahme.m4a',
          controllerFactory: () => fake,
        )),
      );

      await tester.tap(find.byIcon(Icons.share));
      await tester.pump();

      final button = tester.widget<IconButton>(find.byType(IconButton));
      expect(button.onPressed, isNull);

      await tester.tap(find.byIcon(Icons.share));
      await tester.pump();

      expect(fake.shareCallCount, 1);

      fake.shareCompleter!.complete();
      await tester.pump();
      await tester.pump();

      expect(fake.shareCallCount, 1);
    });

    testWidgets('zeigt eine Fehlermeldung, wenn das Teilen fehlschlaegt', (tester) async {
      final fake = _FakeShareController()..throwOnShare = Exception('Kein Ziel gefunden');
      final bytes = Uint8List.fromList([1, 2, 3]);

      await tester.pumpWidget(
        _wrap(ShareButton(
          audioBytes: bytes,
          filename: 'aufnahme.m4a',
          controllerFactory: () => fake,
        )),
      );

      await tester.tap(find.byIcon(Icons.share));
      await tester.pumpAndSettle();

      expect(find.textContaining('Teilen fehlgeschlagen'), findsOneWidget);
    });

    testWidgets(
        'kein setState-Fehler, wenn das Widget waehrend eines ausstehenden Share-Aufrufs '
        'unmounted wird', (tester) async {
      final fake = _FakeShareController()..shareCompleter = Completer<void>();
      final bytes = Uint8List.fromList([1, 2, 3]);

      await tester.pumpWidget(
        _wrap(ShareButton(
          audioBytes: bytes,
          filename: 'aufnahme.m4a',
          controllerFactory: () => fake,
        )),
      );

      await tester.tap(find.byIcon(Icons.share));
      await tester.pump();

      await tester.pumpWidget(_wrap(const SizedBox.shrink()));

      fake.shareCompleter!.complete();
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });
}
