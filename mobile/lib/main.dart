import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'api/api_client.dart';
import 'api/audio_api.dart';
import 'api/midi_api.dart';
import 'screens/home_screen.dart';
import 'state/session_state.dart';

void main() {
  runApp(const SingingFeedbackApp());
}

class SingingFeedbackApp extends StatelessWidget {
  const SingingFeedbackApp({super.key});

  @override
  Widget build(BuildContext context) {
    final apiClient = ApiClient();
    return ChangeNotifierProvider(
      create: (_) => SessionState(
        midiApi: MidiApi(apiClient),
        audioApi: AudioApi(apiClient),
      ),
      child: MaterialApp(
        title: 'Singing Feedback',
        theme: ThemeData(colorSchemeSeed: const Color(0xFF2563EB), useMaterial3: true),
        home: const HomeScreen(),
      ),
    );
  }
}
