import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

/// Duenne Abstraktion ueber die Audio-Wiedergabe, injizierbar fuer Tests.
///
/// [AudioPlayer] selbst ist zwar keine sealed/final/interface-Klasse (also
/// technisch per Subklasse ueberschreibbar), aber sein Konstruktor hat
/// erhebliche Seiteneffekte (stoesst unawaited Plattform-Kanal-Aufrufe in
/// _create() an, legt mehrere StreamController und einen FramePositionUpdater
/// an) - jede Subklasse wuerde diese Seiteneffekte beim Bau ebenfalls
/// durchlaufen, ganz ohne echten Plattform-Kanal in flutter_test. Ein
/// schlankes Interface umgeht das vollstaendig und macht Fakes fuer Tests
/// trivial.
abstract class AudioPlaybackController {
  Future<void> play(Uint8List bytes);
  Future<void> pause();
  Future<void> stop();
  Stream<void> get onComplete;
  void dispose();
}

/// Standardimplementierung, delegiert an das echte audioplayers-Paket.
class _RealAudioPlaybackController implements AudioPlaybackController {
  final AudioPlayer _player = AudioPlayer();

  @override
  Future<void> play(Uint8List bytes) => _player.play(BytesSource(bytes));

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() => _player.stop();

  @override
  Stream<void> get onComplete => _player.onPlayerComplete;

  @override
  void dispose() {
    unawaited(_player.dispose());
  }
}

/// Spielt eine bereits hochgeladene Aufnahme erneut ab (im Gegensatz zu
/// RecordingControls Vorschau, die nur *vor* dem Hochladen existiert). Rendert
/// nichts, solange keine Bytes vorliegen. Gleiches _isBusy-Guard-Muster wie
/// RecordingControl, um dieselbe Await-Race-Klasse zu vermeiden.
class PlaybackButton extends StatefulWidget {
  final Uint8List? audioBytes;

  /// Fabrik fuer den Playback-Controller, injizierbar fuer Tests (siehe
  /// [AudioPlaybackController]). Standardmaessig die echte Implementierung.
  final AudioPlaybackController Function() controllerFactory;

  PlaybackButton({
    super.key,
    required this.audioBytes,
    AudioPlaybackController Function()? controllerFactory,
  }) : controllerFactory = controllerFactory ?? (() => _RealAudioPlaybackController());

  @override
  State<PlaybackButton> createState() => _PlaybackButtonState();
}

class _PlaybackButtonState extends State<PlaybackButton> {
  late final AudioPlaybackController _player = widget.controllerFactory();
  late final StreamSubscription<void> _playerCompleteSubscription;
  bool _isPlaying = false;
  bool _isBusy = false;
  String? _errorMessage;
  Object? _playbackToken;

  @override
  void initState() {
    super.initState();
    _playerCompleteSubscription = _player.onComplete.listen((_) {
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
        await _player.play(widget.audioBytes!);
        if (!mounted || token != _playbackToken) return;
        setState(() => _isPlaying = true);
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
