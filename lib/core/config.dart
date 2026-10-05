/// App-wide configuration.
///
/// The server address is passed at run time, so the same code works everywhere:
///   flutter run -d chrome                                         -> http://127.0.0.1:8000 (default)
///   flutter run --dart-define=API_URL=http://10.0.2.2:8000         -> Android emulator
///   flutter run --dart-define=API_URL=http://192.168.1.20:8000     -> real phone on the same Wi-Fi
class AppConfig {
  static const String apiBaseUrl = String.fromEnvironment('API_URL', defaultValue: 'http://127.0.0.1:8000');
}
