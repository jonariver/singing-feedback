import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/session_state.dart';

/// Spielt eine bereits hochgeladene Aufnahme erneut ab (im Gegensatz zu
/// RecordingControls Vorschau, die nur *vor* dem Hochladen existiert). Rendert
/// nichts, solange keine Bytes vorliegen. Delegiert Wiedergabe/Pause an
/// SessionState (siehe AudioPlaybackController dort) - der Play/Pause-Status
/// kommt aus session.isPlayingAudio(audioBytes), damit mehrere PlaybackButton-
/// Instanzen (Referenz-/Gesangsaufnahme) trotz gemeinsamem Player unabhaengig
/// ihren eigenen Status zeigen. Gleiches _isBusy-Guard-Muster wie
/// RecordingControl, um dieselbe Await-Race-Klasse zu vermeiden.
class PlaybackButton extends StatefulWidget {
  final Uint8List? audioBytes;

  const PlaybackButton({super.key, required this.audioBytes});

  @override
  State<PlaybackButton> createState() => _PlaybackButtonState();
}

class _PlaybackButtonState extends State<PlaybackButton> {
  bool _isBusy = false;
  String? _errorMessage;
  Object? _playbackToken;

  @override
  void didUpdateWidget(covariant PlaybackButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.audioBytes != oldWidget.audioBytes) {
      _errorMessage = null;
      _playbackToken = Object();
      final session = context.read<SessionState>();
      if (session.isPlayingAudio(oldWidget.audioBytes)) {
        unawaited(session.stop());
      }
    }
  }

  Future<void> _togglePlayback(SessionState session) async {
    if (_isBusy || widget.audioBytes == null) return;
    setState(() => _isBusy = true);
    final token = _playbackToken;
    try {
      if (session.isPlayingAudio(widget.audioBytes)) {
        await session.pause();
      } else {
        await session.play(widget.audioBytes!);
      }
    } catch (e) {
      if (!mounted || token != _playbackToken) return;
      setState(() => _errorMessage = 'Wiedergabe fehlgeschlagen: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionState>();
    if (widget.audioBytes == null) return const SizedBox.shrink();
    final isThisPlaying = session.isPlayingAudio(widget.audioBytes);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IconButton(
          onPressed: _isBusy ? null : () => _togglePlayback(session),
          icon: Icon(isThisPlaying ? Icons.pause : Icons.play_arrow),
          tooltip: isThisPlaying ? 'Pause' : 'Erneut abspielen',
        ),
        if (_errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _errorMessage!,
              style: TextStyle(color: Colors.red.shade300, fontSize: 12),
            ),
          ),
      ],
    );
  }
}
