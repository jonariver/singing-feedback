/// Toleranz-Preset fuer die gruen/gelb/rot-Klassifikation der Cent-Abweichung
/// in der Bewertung (siehe
/// docs/superpowers/specs/2026-08-07-tolerance-preset-design.md). Eigene Datei
/// (statt inline in session_state.dart wie ReferenceSource), weil sowohl
/// SessionState als auch ScoreApi dieses Enum brauchen und ScoreApi
/// SessionState nicht importieren darf (Zirkelbezug).
enum TolerancePreset {
  strict,
  normal,
  loose;

  String get apiValue => switch (this) {
        TolerancePreset.strict => 'strict',
        TolerancePreset.normal => 'normal',
        TolerancePreset.loose => 'loose',
      };

  String get label => switch (this) {
        TolerancePreset.strict => 'Streng',
        TolerancePreset.normal => 'Normal',
        TolerancePreset.loose => 'Locker',
      };

  static TolerancePreset? fromApiValue(String? value) {
    for (final preset in TolerancePreset.values) {
      if (preset.apiValue == value) return preset;
    }
    return null;
  }
}
