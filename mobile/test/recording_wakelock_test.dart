import 'package:flutter_test/flutter_test.dart';
import 'package:singing_feedback_mobile/util/recording_wakelock.dart';

void main() {
  test('zwei acquire() loesen genau einen enable-Aufruf aus', () async {
    var enableCalls = 0;
    var disableCalls = 0;
    final wakelock = RecordingWakelock(
      enable: () async => enableCalls++,
      disable: () async => disableCalls++,
    );

    await wakelock.acquire();
    await wakelock.acquire();

    expect(enableCalls, 1);
    expect(disableCalls, 0);
  });

  test('erst der letzte release() loest disable aus', () async {
    var enableCalls = 0;
    var disableCalls = 0;
    final wakelock = RecordingWakelock(
      enable: () async => enableCalls++,
      disable: () async => disableCalls++,
    );

    await wakelock.acquire();
    await wakelock.acquire();
    await wakelock.release();
    expect(disableCalls, 0);
    await wakelock.release();
    expect(disableCalls, 1);
    expect(enableCalls, 1);
  });

  test('einzelnes acquire/release-Paar loest je einen enable/disable aus', () async {
    var enableCalls = 0;
    var disableCalls = 0;
    final wakelock = RecordingWakelock(
      enable: () async => enableCalls++,
      disable: () async => disableCalls++,
    );

    await wakelock.acquire();
    expect(enableCalls, 1);
    expect(disableCalls, 0);
    await wakelock.release();
    expect(disableCalls, 1);
  });

  test('release() ohne vorheriges acquire() ist ein No-op', () async {
    var enableCalls = 0;
    var disableCalls = 0;
    final wakelock = RecordingWakelock(
      enable: () async => enableCalls++,
      disable: () async => disableCalls++,
    );

    await wakelock.release();

    expect(enableCalls, 0);
    expect(disableCalls, 0);
  });

  test('drei acquire() und drei release() balancieren sich exakt aus', () async {
    var enableCalls = 0;
    var disableCalls = 0;
    final wakelock = RecordingWakelock(
      enable: () async => enableCalls++,
      disable: () async => disableCalls++,
    );

    await wakelock.acquire();
    await wakelock.acquire();
    await wakelock.acquire();
    await wakelock.release();
    await wakelock.release();
    expect(disableCalls, 0);
    await wakelock.release();
    expect(enableCalls, 1);
    expect(disableCalls, 1);
  });
}
