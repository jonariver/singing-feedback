class AppConfig {
  const AppConfig._();

  /// Basis-URL des Backends. 10.0.2.2 zeigt im Android-Emulator auf den
  /// Host-localhost; der iOS-Simulator braucht dafuer 127.0.0.1. Fuer ein echtes
  /// Geraet oder ein gehostetes Backend per --dart-define=API_BASE_URL=... ueberschreiben,
  /// z.B.: flutter run --dart-define=API_BASE_URL=https://meine-app.example
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8000',
  );
}
