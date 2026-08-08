import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/session_state.dart';

/// YouTube-artiger Tap-to-Seek-Schieberegler fuer eine Audiospur. Sitzt neben
/// PlaybackButton (siehe dort fuer den geteilten-Player-Kontext) - beide
/// Widgets teilen sich denselben SessionState-Player. Position/Dauer kommen
/// ueber session.positionFor(audioBytes)/durationFor(audioBytes), die nach
/// Bytes-Identitaet gegatet sind, damit mehrere Seekbar-Instanzen (Referenz-/
/// Gesangsaufnahme) trotz gemeinsamem Player nur fuer die tatsaechlich
/// zuletzt geladene/abgespielte Spur eine Position/Dauer anzeigen (fuer jede
/// andere Spur bleibt es bei Duration.zero).
///
/// Nur Slider + m:ss-Labels stecken in zwei verschachtelten
/// StreamBuilder<Duration>s, NICHT das ganze Widget - Positions-Ticks (mehrmals
/// pro Sekunde waehrend der Wiedergabe) sollen keine breiteren Rebuilds
/// ausloesen. Der AEUSSERE StreamBuilder haengt an onDurationChanged und sorgt
/// dafuer, dass ein reiner Dauer-Tick (ohne begleitenden Positions-Tick)
/// ueberhaupt einen Rebuild ausloest; der INNERE haengt an onPositionChanged.
/// Beide Builder-Funktionen lesen durationFor(bytes)/positionFor(bytes) aber
/// jeweils FRISCH neu (nicht nur der aeussere) - sonst wuerde ein Positions-Tick,
/// der nur den inneren Builder neu baut, eine veraltete, im aeusseren Scope
/// eingefangene Dauer weiterverwenden (Regression: bei zwei gleichzeitig
/// montierten Seekbars konnte ein Tick, der waehrend eines Trackwechsels der
/// JEWEILS ANDEREN Bar eintraf, den inneren Builder mit frischer Position=0
/// aber noch alter, nicht mehr gueltiger Dauer rendern).
///
/// Waehrend eines aktiven Drags wird nur lokal (_dragValue) aktualisiert, kein
/// playFrom-Spam auf den geteilten Player - erst onChangeEnd seekt
/// tatsaechlich (gleiches _isBusy/Fehlermeldungs-Muster wie
/// PlaybackButton._togglePlayback bzw. _jumpToPosition in
/// feedback_section.dart). Rendert nichts, solange keine Bytes vorliegen
/// (gleiches Null-Guard-Muster wie PlaybackButton).
class PlaybackSeekbar extends StatefulWidget {
  final Uint8List? audioBytes;

  const PlaybackSeekbar({super.key, required this.audioBytes});

  @override
  State<PlaybackSeekbar> createState() => _PlaybackSeekbarState();
}

class _PlaybackSeekbarState extends State<PlaybackSeekbar> {
  Duration? _dragValue;
  bool _isBusy = false;
  String? _errorMessage;
  Object? _playbackToken;

  @override
  void didUpdateWidget(covariant PlaybackSeekbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.audioBytes != oldWidget.audioBytes) {
      _dragValue = null;
      _errorMessage = null;
      _playbackToken = Object();
    }
  }

  double _secondsOf(Duration d) => d.inMilliseconds / 1000;

  /// Seekt den geteilten Player auf [seconds] (Sekunden vom Slider) fuer
  /// widget.audioBytes, geclamped auf [0, lastKnownDuration]. lastKnownDuration
  /// wird bewusst vom Aufrufer (aus dem StreamBuilder-Scope) hereingereicht statt
  /// hier frisch per session.durationFor(bytes) abgefragt: bei einem echten
  /// Trackwechsel setzt SessionState.playFrom _lastKnownDuration synchron auf
  /// Duration.zero zurueck, noch bevor es zurueckkehrt - ein zweiter Seek, der
  /// waehrend der erste noch haengt frisch nachfragen wuerde, saehe faelschlich
  /// schon 0 statt der tatsaechlichen Spurdauer. (Die Position dagegen wird von
  /// SessionState.playFrom immer optimistisch auf das Seek-Ziel gesetzt, nie
  /// zurueckgesetzt - siehe Kommentar dort.)
  ///
  /// Bewusst OHNE _isBusy-Fruehausstieg (anders als
  /// PlaybackButton._togglePlayback) - ein schneller Doppel-Seek (zwei
  /// onChangeEnd-Aufrufe kurz hintereinander, z.B. zwei rasche Slider-Gesten)
  /// soll beide Male tatsaechlich session.playFrom() erreichen; welcher
  /// Aufruf gewinnt, entscheidet der bereits vorhandene
  /// _playbackGeneration-Schutz in SessionState.playFrom, nicht dieses
  /// Widget.
  Future<void> _seekTo(
      SessionState session, double seconds, Duration lastKnownDuration) async {
    final bytes = widget.audioBytes;
    if (bytes == null) return;
    final lastKnownDurationMillis = lastKnownDuration.inMilliseconds;
    var targetMillis = (seconds * 1000).round();
    if (targetMillis < 0) targetMillis = 0;
    if (targetMillis > lastKnownDurationMillis) {
      targetMillis = lastKnownDurationMillis;
    }
    // Token VOR dem await erfassen (gleiches Muster wie PlaybackButton, siehe
    // playback_button.dart) - falls didUpdateWidget waehrend dieses Seeks auf
    // andere Bytes umschaltet, matcht der neue Token unten nicht mehr und der
    // catch-Block darf keine Fehlermeldung mehr fuer die ALTEN Bytes unter dem
    // NEUEN Track rendern.
    final token = _playbackToken;
    setState(() {
      _dragValue = null;
      _isBusy = true;
    });
    try {
      await session.playFrom(bytes, Duration(milliseconds: targetMillis));
    } catch (e) {
      if (!mounted || token != _playbackToken) return;
      setState(() => _errorMessage = 'Sprung fehlgeschlagen: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.audioBytes == null) return const SizedBox.shrink();
    final bytes = widget.audioBytes!;
    final session = context.read<SessionState>();
    // Bewusst select(), nicht watch() - dieses Widget soll nur bei Aenderung
    // genau dieses einen Play/Pause-Flags neu bauen (z.B. sofortiges 0:00
    // beim Umschalten auf eine andere Spur, ohne auf den naechsten
    // Positions-Tick warten zu muessen), nicht bei jedem notifyListeners()
    // im SessionState.
    final isThisPlaying = context
        .select<SessionState, bool>((s) => s.isPlayingAudio(widget.audioBytes));

    // Der AEUSSERE StreamBuilder existiert nur, damit ein reiner Dauer-Tick
    // (ohne begleitenden Positions-Tick) ueberhaupt einen Rebuild ausloest -
    // er ist NICHT die alleinige Quelle fuer duration/hasDuration. Die
    // eigentlichen Werte werden unten im INNEREN Builder frisch neu gelesen,
    // damit auch ein Positions-Tick (der nur den inneren Builder neu baut)
    // niemals eine im aeusseren Scope veraltete Dauer weiterverwendet (siehe
    // Klassenkommentar oben).
    return StreamBuilder<Duration>(
      stream: session.onDurationChanged,
      initialData: session.durationFor(bytes),
      builder: (context, _) {
        return StreamBuilder<Duration>(
          stream: session.onPositionChanged,
          initialData: session.positionFor(bytes),
          builder: (context, __) {
            final duration = session.durationFor(bytes);
            final durationSeconds = _secondsOf(duration);
            final hasDuration = durationSeconds > 0;
            final rawPosition = session.positionFor(bytes);
            var positionSeconds = _secondsOf(_dragValue ?? rawPosition);
            if (!hasDuration || positionSeconds < 0) {
              positionSeconds = 0;
            } else if (positionSeconds > durationSeconds) {
              positionSeconds = durationSeconds;
            }

            return Opacity(
              // Nur ein visueller Hinweis waehrend ein Seek unterwegs ist -
              // KEIN Deaktivieren von onChangeEnd (das wuerde einen schnellen
              // Doppel-Seek verhindern, siehe _seekTo-Kommentar).
              opacity: _isBusy ? 0.6 : 1.0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Slider(
                    value: hasDuration ? positionSeconds : 0,
                    min: 0,
                    max: hasDuration ? durationSeconds : 1,
                    activeColor: isThisPlaying ? null : Colors.grey,
                    onChanged: hasDuration
                        ? (v) => setState(
                              () => _dragValue =
                                  Duration(milliseconds: (v * 1000).round()),
                            )
                        : null,
                    onChangeEnd: hasDuration
                        ? (v) => _seekTo(session, v, duration)
                        : null,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(formatDurationMinSec(positionSeconds)),
                        Text(formatDurationMinSec(durationSeconds)),
                      ],
                    ),
                  ),
                  if (_errorMessage != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        _errorMessage!,
                        style:
                            TextStyle(color: Colors.red.shade300, fontSize: 12),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
