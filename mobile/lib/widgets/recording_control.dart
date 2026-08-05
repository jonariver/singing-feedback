import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

/// Nimmt per Mikrofon auf oder laesst alternativ eine vorhandene Audiodatei waehlen
/// (Datei-Fallback = Paritaet mit dem heutigen <input type="file"> in app.js, das
/// Mikrofon selbst ist eine bewusste Ergaenzung fuer die Mobile-App). Vor dem Hochladen
/// kann die Aufnahme/Datei erst angehoert und verworfen werden - erst ein expliziter
/// "Verwenden"-Tap liefert (bytes, filename) an [onAudioReady], das denselben
/// POST /api/audio/analyze-Aufruf ausloest wie im Web-Frontend.
class RecordingControl extends StatefulWidget {
  final bool enabled;
  final void Function(Uint8List bytes, String filename) onAudioReady;

  const RecordingControl({super.key, required this.enabled, required this.onAudioReady});

  @override
  State<RecordingControl> createState() => _RecordingControlState();
}

class _RecordingControlState extends State<RecordingControl> {
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  late final StreamSubscription<void> _playerCompleteSubscription;
  bool _isRecording = false;
  bool _isPlaying = false;
  bool _isBusy = false;
  Uint8List? _pendingAudio;
  String? _pendingFilename;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _playerCompleteSubscription = _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _isPlaying = false);
    });
  }

  @override
  void dispose() {
    _playerCompleteSubscription.cancel();
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _startRecording() async {
    setState(() => _errorMessage = null);
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      setState(() => _errorMessage = 'Mikrofon-Berechtigung wurde nicht erteilt.');
      return;
    }

    final dir = await Directory.systemTemp.createTemp('singing_feedback_');
    final path = '${dir.path}/aufnahme.m4a';
    // Explizit AAC/M4A statt Paket-Default: beide Plattformen (Android MediaRecorder,
    // iOS AVAudioRecorder) unterstuetzen das nativ, und der PyAV-Fallback in
    // backend/pitch_detection/pyin.py deckt .m4a-Dekodierung serverseitig ab.
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
    setState(() => _isRecording = true);
  }

  Future<void> _stopRecording() async {
    final path = await _recorder.stop();
    setState(() => _isRecording = false);
    if (path == null) return;
    final bytes = await File(path).readAsBytes();
    setState(() {
      _pendingAudio = bytes;
      _pendingFilename = 'aufnahme.m4a';
    });
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['wav', 'mp3', 'flac', 'ogg', 'm4a', 'webm'],
      withData: true,
    );
    final file = result?.files.single;
    if (file?.bytes == null) return;
    setState(() {
      _pendingAudio = file!.bytes!;
      _pendingFilename = file.name;
    });
  }

  Future<void> _togglePlayback() async {
    try {
      if (_isPlaying) {
        await _player.pause();
        setState(() => _isPlaying = false);
      } else {
        await _player.play(BytesSource(_pendingAudio!));
        setState(() => _isPlaying = true);
      }
    } catch (e) {
      setState(() => _errorMessage = 'Wiedergabe fehlgeschlagen: $e');
    }
  }

  Future<void> _discard() async {
    if (_isBusy) return;
    if (_isPlaying) {
      setState(() => _isBusy = true);
      await _player.stop();
    } else {
      setState(() => _isBusy = true);
    }
    setState(() {
      _pendingAudio = null;
      _pendingFilename = null;
      _isPlaying = false;
      _isBusy = false;
    });
  }

  Future<void> _confirm() async {
    if (_isBusy) return;
    final bytes = _pendingAudio;
    final filename = _pendingFilename;
    if (bytes == null || filename == null) return;
    if (_isPlaying) {
      setState(() => _isBusy = true);
      await _player.stop();
    } else {
      setState(() => _isBusy = true);
    }
    setState(() {
      _pendingAudio = null;
      _pendingFilename = null;
      _isPlaying = false;
      _isBusy = false;
    });
    widget.onAudioReady(bytes, filename);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_pendingAudio == null)
          Row(
            children: [
              ElevatedButton.icon(
                onPressed:
                    widget.enabled ? (_isRecording ? _stopRecording : _startRecording) : null,
                icon: Icon(_isRecording ? Icons.stop : Icons.mic),
                label: Text(_isRecording ? 'Aufnahme stoppen' : 'Aufnehmen'),
              ),
              const SizedBox(width: 12),
              TextButton.icon(
                onPressed: widget.enabled && !_isRecording ? _pickFile : null,
                icon: const Icon(Icons.folder_open),
                label: const Text('Datei wählen'),
              ),
            ],
          )
        else
          Row(
            children: [
              IconButton(
                onPressed: _isBusy ? null : _togglePlayback,
                icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                tooltip: _isPlaying ? 'Pause' : 'Abspielen',
              ),
              IconButton(
                onPressed: _isBusy ? null : _discard,
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Löschen',
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: _isBusy ? null : _confirm,
                child: const Text('Verwenden'),
              ),
            ],
          ),
        if (_errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(_errorMessage!, style: TextStyle(color: Colors.red.shade700)),
          ),
      ],
    );
  }
}
