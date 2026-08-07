import 'package:wakelock_plus/wakelock_plus.dart';

/// Haelt das Display waehrend einer laufenden Mikrofonaufnahme wach
/// (Android-Display-Timeout fuehrt sonst bestaetigt zu lautlosem
/// Audioverlust). Ein Referenzzaehler erlaubt mehreren unabhaengigen
/// Aufnahme-Widgets (Referenz- und Gesangsaufnahme), sich denselben
/// Wakelock-Zustand zu teilen, ohne sich gegenseitig vorzeitig
/// abzuschalten.
class RecordingWakelock {
  RecordingWakelock({
    Future<void> Function() enable = WakelockPlus.enable,
    Future<void> Function() disable = WakelockPlus.disable,
  })  : _enable = enable,
        _disable = disable;

  final Future<void> Function() _enable;
  final Future<void> Function() _disable;
  int _activeRecordings = 0;

  Future<void> acquire() async {
    _activeRecordings++;
    if (_activeRecordings == 1) {
      await _enable();
    }
  }

  Future<void> release() async {
    if (_activeRecordings == 0) return;
    _activeRecordings--;
    if (_activeRecordings == 0) {
      await _disable();
    }
  }
}

/// Von allen RecordingControl-Instanzen geteiltes Singleton.
final RecordingWakelock recordingWakelock = RecordingWakelock();
