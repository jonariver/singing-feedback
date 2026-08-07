import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'dart:async';

import 'api/api_client.dart';
import 'api/audio_api.dart';
import 'api/midi_api.dart';
import 'api/score_api.dart';
import 'api/feedback_api.dart';
import 'api/sync_api.dart';
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
      create: (_) {
        final session = SessionState(
          midiApi: MidiApi(apiClient),
          audioApi: AudioApi(apiClient),
          syncApi: SyncApi(apiClient),
          scoreApi: ScoreApi(apiClient),
          feedbackApi: FeedbackApi(apiClient),
        );
        unawaited(session.loadPersistedTolerancePreset());
        return session;
      },
      child: MaterialApp(
        title: 'Singing Feedback',
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF00C2CB),
            brightness: Brightness.dark,
          ).copyWith(
            primary: const Color(0xFF00C2CB),
            secondary: const Color(0xFF39C0D4),
            surface: const Color(0xFF121111),
            onSurfaceVariant: const Color(0xFF8A9A9D),
          ),
          textTheme: GoogleFonts.jostTextTheme(ThemeData(brightness: Brightness.dark).textTheme),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(shape: const StadiumBorder()),
          ),
          segmentedButtonTheme: SegmentedButtonThemeData(
            style: SegmentedButton.styleFrom(shape: const StadiumBorder()),
          ),
        ),
        home: const HomeScreen(),
      ),
    );
  }
}
