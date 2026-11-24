import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device-wide settings (shared by all profiles).
class AppSettings extends ChangeNotifier {
  AppSettings(this._prefs);
  final SharedPreferences _prefs;

  static Future<AppSettings> load() async =>
      AppSettings(await SharedPreferences.getInstance());

  bool get cacheEnabled => _prefs.getBool('cacheEnabled') ?? false;
  int get cacheMaxMb => _prefs.getInt('cacheMaxMb') ?? 2048;
  String? get cookiesPath => _prefs.getString('cookiesPath');
  int? get lastProfileId => _prefs.getInt('lastProfileId');

  int get cacheMaxBytes => cacheMaxMb * 1024 * 1024;

  Future<void> setCacheEnabled(bool v) async {
    await _prefs.setBool('cacheEnabled', v);
    notifyListeners();
  }

  Future<void> setCacheMaxMb(int v) async {
    await _prefs.setInt('cacheMaxMb', v);
    notifyListeners();
  }

  Future<void> setCookiesPath(String? v) async {
    if (v == null || v.isEmpty) {
      await _prefs.remove('cookiesPath');
    } else {
      await _prefs.setString('cookiesPath', v);
    }
    notifyListeners();
  }

  Future<void> setLastProfileId(int? id) async {
    if (id == null) {
      await _prefs.remove('lastProfileId');
    } else {
      await _prefs.setInt('lastProfileId', id);
    }
  }
}
