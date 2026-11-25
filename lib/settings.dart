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

  /// Discord Rich Presence (desktop). Off unless the user turns it on.
  bool get discordEnabled => _prefs.getBool('discordEnabled') ?? false;

  /// Application ID from discord.com/developers. A release build ships one (--dart-define=DISCORD_CLIENT_ID=...);
  /// when it does, that is the one used and Settings does not ask. Builds without one let the user type their own.
  static const builtInDiscordClientId = String.fromEnvironment('DISCORD_CLIENT_ID');
  static bool get hasBuiltInDiscordClientId => builtInDiscordClientId.isNotEmpty;
  String get discordClientId => hasBuiltInDiscordClientId ? builtInDiscordClientId : (_prefs.getString('discordClientId') ?? '').trim();
  bool get hasCustomDiscordClientId => !hasBuiltInDiscordClientId && discordClientId.isNotEmpty;

  /// Look for a new app version at launch and once a day.
  bool get autoUpdateCheck => _prefs.getBool('autoUpdateCheck') ?? true;

  /// The version whose "update available" banner was closed with "Later".
  String? get dismissedUpdate => _prefs.getString('dismissedUpdate');

  int get cacheMaxBytes => cacheMaxMb * 1024 * 1024;

  Future<void> setCacheEnabled(bool v) async {
    await _prefs.setBool('cacheEnabled', v);
    notifyListeners();
  }

  Future<void> setCacheMaxMb(int v) async {
    await _prefs.setInt('cacheMaxMb', v);
    notifyListeners();
  }

  Future<void> setDiscordEnabled(bool v) async {
    await _prefs.setBool('discordEnabled', v);
    notifyListeners();
  }

  Future<void> setDiscordClientId(String? v) async {
    v = v?.trim();
    if (v == null || v.isEmpty) {
      await _prefs.remove('discordClientId');
    } else {
      await _prefs.setString('discordClientId', v);
    }
    notifyListeners();
  }

  Future<void> setAutoUpdateCheck(bool v) async {
    await _prefs.setBool('autoUpdateCheck', v);
    notifyListeners();
  }

  Future<void> setDismissedUpdate(String? version) async {
    if (version == null) {
      await _prefs.remove('dismissedUpdate');
    } else {
      await _prefs.setString('dismissedUpdate', version);
    }
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
