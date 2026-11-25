import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../settings.dart';
import 'installer.dart';
import 'updater.dart';

enum UpdatePhase { idle, checking, upToDate, available, downloading, ready, installing, failed }

/// Drives the update screens: checks at launch and then daily, downloads on request, starts the installer.
class UpdateController extends ChangeNotifier {
  UpdateController({
    required this.updater,
    required this.installer,
    required this.settings,
    required this.downloadDir,
    this.interval = const Duration(hours: 24),
  });

  final Updater updater;
  final UpdateInstaller installer;
  final AppSettings settings;
  final Future<Directory> Function() downloadDir;
  final Duration interval;

  UpdatePhase phase = UpdatePhase.idle;
  ReleaseInfo? release;
  double progress = 0;
  String? error;
  bool needsPermission = false;

  File? _file; // verified download of [release]
  CancelToken? _cancel;
  Timer? _first, _every;

  /// False in builds that were not made from a release tag.
  bool get enabled => updater.currentVersion != null;

  /// Whether this device can install [release] itself (otherwise the user gets the download page).
  bool get canInstall => installer.assetName != null && (release?.assets.containsKey(installer.assetName) ?? false);

  bool get showBanner => release != null && phase != UpdatePhase.installing && settings.dismissedUpdate != release!.version.toString();

  bool get _busy => phase == UpdatePhase.checking || phase == UpdatePhase.downloading || phase == UpdatePhase.installing;

  void start({Duration delay = const Duration(seconds: 5)}) {
    if (!enabled) return;
    void auto() {
      if (settings.autoUpdateCheck) check();
    }

    _first = Timer(delay, auto);
    _every = Timer.periodic(interval, (_) => auto());
  }

  Future<void> check() async {
    if (!enabled || _busy) return;
    final before = phase;
    phase = UpdatePhase.checking;
    error = null;
    notifyListeners();
    try {
      final found = await updater.check();
      if (found?.version != release?.version) {
        _file = null;
        needsPermission = false;
      }
      release = found;
      phase = found == null ? UpdatePhase.upToDate : (_file == null ? UpdatePhase.available : UpdatePhase.ready);
    } catch (e) {
      error = '$e';
      phase = release == null ? UpdatePhase.failed : before; // keep offering what was already found
    }
    notifyListeners();
  }

  /// "Later": hides the banner for this version. Settings still offers it.
  Future<void> dismiss() async {
    await settings.setDismissedUpdate(release?.version.toString());
    notifyListeners();
  }

  /// Downloads (if needed) and installs; on devices that cannot, opens the release page.
  Future<void> update() async {
    final r = release;
    if (r == null || _busy) return;
    error = null;
    if (!canInstall) {
      try {
        await installer.openPage(r.page);
      } catch (_) {
        error = 'Could not open the browser. The download is at ${r.page}';
      }
      notifyListeners();
      return;
    }
    if (_file == null || !await _file!.exists()) {
      final cancel = _cancel = CancelToken();
      phase = UpdatePhase.downloading;
      progress = 0;
      notifyListeners();
      try {
        _file = await updater.download(r, installer.assetName!, await downloadDir(), cancel: cancel, onProgress: (f) {
          // Redraw once per percent, not once per network packet.
          if ((f * 100).floor() != (progress * 100).floor()) {
            progress = f;
            notifyListeners();
          }
        });
      } catch (e) {
        if (e is! UpdateCancelled) error = '$e';
        phase = UpdatePhase.available;
        notifyListeners();
        return;
      }
    }
    await install();
  }

  Future<void> install() async {
    final f = _file;
    if (f == null || phase == UpdatePhase.installing) return;
    phase = UpdatePhase.installing;
    error = null;
    needsPermission = false;
    notifyListeners();
    try {
      final result = await installer.install(f);
      if (result != InstallResult.restarting) {
        phase = UpdatePhase.ready; // the user may still cancel in the system installer, so allow another try
        needsPermission = result == InstallResult.needsPermission;
      }
    } catch (e) {
      phase = UpdatePhase.ready;
      error = 'Could not start the installer: $e';
    }
    notifyListeners();
  }

  void cancel() => _cancel?.cancel();

  @override
  void dispose() {
    _first?.cancel();
    _every?.cancel();
    super.dispose();
  }
}
