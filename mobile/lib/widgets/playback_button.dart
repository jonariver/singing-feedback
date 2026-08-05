import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

/// Spielt eine bereits hochgeladene Aufnahme erneut ab (im Gegensatz zu
/// RecordingControls Vorschau, die nur *vor* dem Hochladen existiert). Rendert
/// nichts, solange keine Bytes vorliegen. Gleiches _isBusy-Guard-Muster wie
/// RecordingControl, um dieselbe Await-Race-Klasse zu vermeiden.
class PlaybackButton extends StatefulWidget {
  final Uint8List? audioBytes;

  const PlaybackButton({super.key, required this.audioBytes});

  @override
  State<PlaybackButton> createState() => _PlaybackButtonState();
}

class _PlaybackButtonState extends State<PlaybackButton> {
  final AudioPlayer _player = AudioPlayer();
  late final StreamSubscription<void> _playerCompleteSubscription;
  bool _isPlaying = false;
  bool _isBusy = false;
  String? _errorMessage;
  Object? _playbackToken;

  @override
  void initState() {
    super.initState();
    _playerCompleteSubscription = _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _isPlaying = false);
    });
  }

  @override
  void didUpdateWidget(covariant PlaybackButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.audioBytes != oldWidget.audioBytes) {
      unawaited(_player.stop());
      _isPlaying = false;
      _errorMessage = null;
      _playbackToken = Object();
    }
  }

  @override
  void dispose() {
    _playerCompleteSubscription.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlayback() async {
    if (_isBusy || widget.audioBytes == null) return;
    setState(() => _isBusy = true);
    final token = _playbackToken;
    try {
      if (_isPlaying) {
        await _player.pause();
        if (!mounted || token != _playbackToken) return;
        setState(() => _isPlaying = false);
      } else {
        await _player.play(BytesSource(widget.audioBytes!));
        if (!mounted || token != _playbackToken) return;
        setState(() => _isPlaying = true);
      }
    } catch (e) {
      setState(() => _errorMessage = 'Wiedergabe fehlgeschlagen: $e');
    } finally {
      setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.audioBytes == null) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IconButton(
          onPressed: _isBusy ? null : _togglePlayback,
          icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
          tooltip: _isPlaying ? 'Pause' : 'Erneut abspielen',
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
