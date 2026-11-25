import 'dart:io';

enum InstallResult {
  /// The app is about to quit; the installer will open it again.
  restarting,

  /// The system's own installer is on screen and the user confirms there.
  handedToSystem,

  /// The user first has to allow this app to install apps, then try again.
  needsPermission,
}

/// What this device can do with a new release.
abstract class UpdateInstaller {
  /// The release file this device installs by itself, or null when it can only point at the download page.
  String? get assetName;
  Future<InstallResult> install(File file);
  Future<void> openPage(Uri page);
}

typedef ProcessStarter = Future<void> Function(String executable, List<String> arguments);

Future<void> _startDetached(String executable, List<String> arguments) async {
  await Process.start(executable, arguments, mode: ProcessStartMode.detached);
}

/// Windows (installed with the installer): runs the new installer silently and quits.
/// Portable Windows copies, Linux and macOS: open the release page.
class DesktopInstaller implements UpdateInstaller {
  DesktopInstaller({
    required this.operatingSystem,
    required this.executable,
    required this.quit,
    ProcessStarter? start,
  }) : _start = start ?? _startDetached;

  /// As in [Platform.operatingSystem].
  final String operatingSystem;
  final String executable;

  /// Saves what needs saving and ends the app, so the installer can replace its files.
  final Future<void> Function() quit;
  final ProcessStarter _start;

  static const windowsSetup = '404tunes-windows-x64-setup.exe';

  /// See windows/installer/404tunes.iss for RELAUNCH.
  static const setupArguments = ['/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS', '/NORESTARTAPPLICATIONS', '/RELAUNCH=1'];

  /// Inno Setup leaves its uninstaller (unins000.exe) next to the app; the portable zip has none.
  late final bool installedBySetup = () {
    if (operatingSystem != 'windows') return false;
    try {
      return File(executable).parent.listSync().any((f) => RegExp(r'unins\d{3}\.exe$', caseSensitive: false).hasMatch(f.path));
    } catch (_) {
      return false;
    }
  }();

  @override
  String? get assetName => installedBySetup ? windowsSetup : null;

  @override
  Future<InstallResult> install(File file) async {
    await _start(file.path, setupArguments);
    await quit();
    return InstallResult.restarting;
  }

  @override
  Future<void> openPage(Uri page) async {
    if (page.scheme != 'https' || page.host != 'github.com') throw ArgumentError('unexpected release page $page');
    final url = page.toString();
    switch (operatingSystem) {
      case 'windows':
        await _start('rundll32', ['url.dll,FileProtocolHandler', url]);
      case 'macos':
        await _start('open', [url]);
      default:
        await _start('xdg-open', [url]);
    }
  }
}
