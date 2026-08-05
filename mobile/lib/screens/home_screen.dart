import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/session_state.dart';
import '../widgets/pitch_chart.dart';
import '../widgets/playback_button.dart';
import '../widgets/recording_control.dart';
import '../widgets/status_banner.dart';
import '../widgets/track_candidate_card.dart';
import '../widgets/transpose_control.dart';

/// Einzelner Screen, spiegelt den Ablauf von frontend/index.html/app.js:
/// 1. MIDI hochladen -> Spurliste, 2. Spur waehlen (+ optional transponieren),
/// 3. Aufnehmen/hochladen, 4. Kurven-Overlay.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Future<void> _pickMidi(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['mid', 'midi'],
      withData: true,
    );
    final file = result?.files.single;
    if (file?.bytes == null) return;
    if (!context.mounted) return;
    await context.read<SessionState>().uploadMidi(file!.bytes!, file.name);
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionState>();

    return Scaffold(
      appBar: AppBar(title: const Text('Singing Feedback')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('1. Zielmelodie', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SegmentedButton<ReferenceSource>(
              segments: const [
                ButtonSegment(value: ReferenceSource.recording, label: Text('Eigene Aufnahme')),
                ButtonSegment(value: ReferenceSource.midi, label: Text('MIDI-Datei')),
              ],
              selected: {session.referenceSource},
              onSelectionChanged: (selection) => session.setReferenceSource(selection.first),
            ),
            const SizedBox(height: 8),
            if (session.referenceSource == ReferenceSource.midi) ...[
              ElevatedButton.icon(
                onPressed: () => _pickMidi(context),
                icon: const Icon(Icons.upload_file),
                label: const Text('MIDI-Datei wählen'),
              ),
              StatusBanner(status: session.midiStatus, message: session.midiMessage),
              ...session.candidates.map(
                (c) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TrackCandidateCard(
                    candidate: c,
                    selected: session.selectedTrackIndex == c.index,
                    onSelect: () => session.selectTrack(c.index),
                  ),
                ),
              ),
            ] else ...[
              RecordingControl(
                enabled: true,
                onAudioReady: (bytes, filename) => session.analyzeReference(bytes, filename),
              ),
              Row(
                children: [
                  Expanded(
                    child: StatusBanner(
                      status: session.referenceStatus,
                      message: session.referenceMessage,
                    ),
                  ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 180),
                    child: PlaybackButton(audioBytes: session.referenceAudioBytes),
                  ),
                ],
              ),
            ],
            if (session.audioSectionEnabled) ...[
              const SizedBox(height: 8),
              TransposeControl(
                value: session.displayedTranspose,
                onChanged: session.setTranspose,
              ),
            ],
            const Divider(height: 32),
            Text('2. Gesangsaufnahme', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            RecordingControl(
              enabled: session.audioSectionEnabled,
              onAudioReady: (bytes, filename) => session.analyzeAudio(bytes, filename),
            ),
            Row(
              children: [
                Expanded(
                  child: StatusBanner(
                    status: session.audioStatus,
                    message: session.audioMessage,
                  ),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: PlaybackButton(audioBytes: session.sungAudioBytes),
                ),
              ],
            ),
            const Divider(height: 32),
            Text('3. Tonhöhen-Vergleich', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SizedBox(
              height: 300,
              width: double.infinity,
              child: PitchChart(
                targetCurve: session.displayedTargetCurve,
                sungCurve: session.sungCurve,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
