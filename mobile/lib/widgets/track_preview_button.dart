import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/session_state.dart';

/// Hoerprobe (Sinus-Synth) eines MIDI-Spurkandidaten vor der Auswahl. Holt die
/// Vorschau-Bytes lazy beim ersten Tap ueber SessionState.previewBytesForTrack
/// (dort gecacht) und spielt sie ueber den zentralisierten SessionState-Player ab -
/// kein eigener AudioPlayer, gleiches Muster wie PlaybackButton/ShareButton.
class TrackPreviewButton extends StatefulWidget {
  final int trackIndex;

  const TrackPreviewButton({super.key, required this.trackIndex});

  @override
  State<TrackPreviewButton> createState() => _TrackPreviewButtonState();
}

class _TrackPreviewButtonState extends State<TrackPreviewButton> {
  bool _isBusy = false;
  String? _errorMessage;

  Future<void> _toggle(SessionState session) async {
    if (_isBusy) return;
    setState(() {
      _isBusy = true;
      _errorMessage = null;
    });
    try {
      final cached = session.cachedPreviewBytes(widget.trackIndex);
      if (cached != null && session.isPlayingAudio(cached)) {
        await session.pause();
      } else {
        final bytes = await session.previewBytesForTrack(widget.trackIndex);
        if (!mounted) return;
        await session.play(bytes);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Vorschau fehlgeschlagen: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionState>();
    final cached = session.cachedPreviewBytes(widget.trackIndex);
    final isThisPlaying = cached != null && session.isPlayingAudio(cached);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OutlinedButton.icon(
          onPressed: _isBusy ? null : () => _toggle(session),
          icon: Icon(isThisPlaying ? Icons.pause : Icons.play_arrow),
          label: Text(isThisPlaying ? 'Pause' : 'Anhören'),
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
