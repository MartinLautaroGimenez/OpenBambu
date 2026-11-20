import 'package:shared_preferences/shared_preferences.dart';

/// Preferencias persistentes (compartidas con el servicio en segundo plano).
class SettingsStore {
  static const _kUrl = 'server_url';
  static const _kToken = 'api_token';
  static const _kBackground = 'background_monitor';
  static const _kLastEvent = 'last_event_id';
  static const _kSelected = 'selected_printer';

  final SharedPreferences prefs;
  SettingsStore(this.prefs);

  static Future<SettingsStore> load() async => SettingsStore(await SharedPreferences.getInstance());

  String get serverUrl => prefs.getString(_kUrl) ?? '';
  String get token => prefs.getString(_kToken) ?? '';
  bool get configured => serverUrl.isNotEmpty && token.isNotEmpty;
  bool get backgroundMonitor => prefs.getBool(_kBackground) ?? true;
  int get lastEventId => prefs.getInt(_kLastEvent) ?? 0;
  String? get selectedPrinter => prefs.getString(_kSelected);

  Future<void> setServer(String url, String token) async {
    await prefs.setString(_kUrl, url);
    await prefs.setString(_kToken, token);
  }

  Future<void> setBackgroundMonitor(bool v) => prefs.setBool(_kBackground, v);
  Future<void> setLastEventId(int v) => prefs.setInt(_kLastEvent, v);
  Future<void> setSelectedPrinter(String id) => prefs.setString(_kSelected, id);

  Future<void> clear() async {
    await prefs.remove(_kUrl);
    await prefs.remove(_kToken);
    await prefs.remove(_kLastEvent);
  }
}
