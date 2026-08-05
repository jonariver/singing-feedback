import 'track_candidate.dart';

/// Spiegelt die JSON-Antwort von POST /api/midi/upload.
class MidiUploadResult {
  final String sessionId;
  final List<TrackCandidate> candidates;
  final bool hasPlausibleVocalTrack;

  const MidiUploadResult({
    required this.sessionId,
    required this.candidates,
    required this.hasPlausibleVocalTrack,
  });

  factory MidiUploadResult.fromJson(Map<String, dynamic> json) {
    return MidiUploadResult(
      sessionId: json['session_id'] as String,
      candidates: (json['candidates'] as List)
          .cast<Map<String, dynamic>>()
          .map(TrackCandidate.fromJson)
          .toList(),
      hasPlausibleVocalTrack: json['has_plausible_vocal_track'] as bool,
    );
  }
}
