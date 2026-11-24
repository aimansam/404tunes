import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'backend.dart';
import 'models.dart';

/// Desktop: spawn the yt-dlp binary that ships inside the app (assets/bin/OS/).
/// It is copied to the app-support folder on first run, so `yt-dlp -U` can update it in place.
/// A bundled quickjs-ng (`qjs`) is the JavaScript runtime yt-dlp can use to solve YouTube's challenges.
class DesktopBackend implements YtBackend {
  DesktopBackend({this.exeOverride, this.qjsOverride});

  /// Tests / the smoke tool can point at binaries that are already on disk.
  final String? exeOverride;
  final String? qjsOverride;

  String? _exe;
  String? _qjs;
  Future<void>? _init;

  static String get _os =>
      Platform.isWindows ? 'windows' : (Platform.isMacOS ? 'macos' : 'linux');
  static String get _ext => Platform.isWindows ? '.exe' : '';

  @override
  Future<void> init() => _init ??= _doInit();

  Future<void> _doInit() async {
    if (exeOverride != null && qjsOverride != null) {
      _exe = exeOverride;
      _qjs = qjsOverride;
      return;
    }
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'bin'));
    await dir.create(recursive: true);
    Future<String> extract(String name) async {
      final f = File(p.join(dir.path, '$name$_ext'));
      if (!await f.exists()) {
        final data = await rootBundle.load('assets/bin/$_os/$name$_ext');
        await f.writeAsBytes(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
            flush: true);
        if (!Platform.isWindows) await Process.run('chmod', ['755', f.path]);
      }
      return f.path;
    }

    _exe = await extract('yt-dlp');
    _qjs = await extract('qjs');
  }

  @override
  Future<String> run(List<String> args,
      {Duration timeout = const Duration(seconds: 120), bool js = true}) async {
    await init();
    final proc = await Process.start(
      _exe!,
      [
        '--no-js-runtimes',
        if (js) ...['--js-runtimes', 'quickjs:$_qjs'],
        ...args,
      ],
      environment: {'PYTHONUTF8': '1'},
    );
    final out = StringBuffer();
    final err = StringBuffer();
    final done = Future.wait([
      proc.stdout.transform(utf8.decoder).forEach(out.write),
      proc.stderr.transform(utf8.decoder).forEach(err.write),
    ]);
    final code = await proc.exitCode.timeout(timeout, onTimeout: () {
      proc.kill();
      return -1;
    });
    await done;
    if (code != 0) {
      final lines = err.toString().trim().split('\n');
      final msg = lines.where((l) => l.contains('ERROR')).lastOrNull ??
          lines.lastOrNull ??
          'yt-dlp failed ($code)';
      throw YtException(code == -1 ? 'yt-dlp timed out' : msg);
    }
    return out.toString();
  }

  @override
  Future<String> update() async {
    await init();
    // Standalone builds update themselves in place.
    final r = await Process.run(_exe!, ['-U']);
    if (r.exitCode != 0) {
      throw YtException('update failed: ${('${r.stderr}').trim()}');
    }
    return version();
  }

  @override
  Future<String> version() async => (await run(['--version'])).trim();
}
