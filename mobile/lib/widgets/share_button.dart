import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

/// Duenne Abstraktion ueber den nativen Teilen-Dialog, injizierbar fuer Tests -
/// analog zu AudioPlaybackController in playback_button.dart.
abstract class ShareController {
  Future<void> shareBytes(Uint8List bytes, String filename);
}

/// Standardimplementierung, delegiert an share_plus. Baut die Datei direkt aus
/// den im Speicher gehaltenen Bytes (XFile.fromData) - kein Umweg ueber eine
/// temporaere Datei, passend zur bestehenden Praxis im Projekt (siehe
/// PlaybackButton, das genauso BytesSource statt einer Temp-Datei nutzt).
class _RealShareController implements ShareController {
  @override
  Future<void> shareBytes(Uint8List bytes, String filename) async {
    final file = XFile.fromData(bytes, name: filename, mimeType: _mimeTypeFor(filename));
    await SharePlus.instance.share(ShareParams(files: [file], fileNameOverrides: [filename]));
  }

  String? _mimeTypeFor(String filename) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.m4a')) return 'audio/mp4';
    if (lower.endsWith('.wav')) return 'audio/wav';
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    return null;
  }
}

/// Teilt eine bereits hochgeladene Gesangsaufnahme ueber den nativen
/// Betriebssystem-Teilen-Dialog (WhatsApp, andere Messenger, ...). Rendert
/// nichts, solange keine Aufnahme vorliegt. Gleiches _isBusy-Guard-Muster wie
/// PlaybackButton, um Doppel-Taps waehrend des offenen Teilen-Dialogs zu
/// vermeiden.
class ShareButton extends StatefulWidget {
  final Uint8List? audioBytes;
  final String? filename;

  /// Fabrik fuer den Share-Controller, injizierbar fuer Tests (siehe
  /// [ShareController]). Standardmaessig die echte Implementierung.
  final ShareController Function() controllerFactory;

  ShareButton({
    super.key,
    required this.audioBytes,
    required this.filename,
    ShareController Function()? controllerFactory,
  }) : controllerFactory = controllerFactory ?? (() => _RealShareController());

  @override
  State<ShareButton> createState() => _ShareButtonState();
}

class _ShareButtonState extends State<ShareButton> {
  late final ShareController _controller = widget.controllerFactory();
  bool _isBusy = false;
  String? _errorMessage;

  @override
  void didUpdateWidget(covariant ShareButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.audioBytes != oldWidget.audioBytes || widget.filename != oldWidget.filename) {
      _errorMessage = null;
    }
  }

  Future<void> _share() async {
    if (_isBusy || widget.audioBytes == null || widget.filename == null) return;
    setState(() {
      _isBusy = true;
      _errorMessage = null;
    });
    try {
      await _controller.shareBytes(widget.audioBytes!, widget.filename!);
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Teilen fehlgeschlagen: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.audioBytes == null || widget.filename == null) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IconButton(
          onPressed: _isBusy ? null : _share,
          icon: const Icon(Icons.share),
          tooltip: 'Teilen',
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
