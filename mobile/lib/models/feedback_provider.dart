/// Waehlbarer Anbieter fuer die Claude-Feedback-Generierung (Phase 6, siehe
/// docs/superpowers/specs/2026-08-08-cloudflare-feedback-provider-design.md).
/// Eigene Datei (statt inline in session_state.dart wie ReferenceSource), weil
/// sowohl SessionState als auch FeedbackApi dieses Enum brauchen und FeedbackApi
/// SessionState nicht importieren darf (Zirkelbezug) - gleiche Begruendung wie
/// bei TolerancePreset.
enum FeedbackProvider {
  anthropic,
  cloudflare;

  String get apiValue => switch (this) {
        FeedbackProvider.anthropic => 'anthropic',
        FeedbackProvider.cloudflare => 'cloudflare',
      };

  String get label => switch (this) {
        FeedbackProvider.anthropic => 'Claude',
        FeedbackProvider.cloudflare => 'Cloudflare',
      };

  static FeedbackProvider? fromApiValue(String? value) {
    for (final provider in FeedbackProvider.values) {
      if (provider.apiValue == value) return provider;
    }
    return null;
  }
}
