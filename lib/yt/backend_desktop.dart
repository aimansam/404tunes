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
  DesktopBackend({this.exeOverride, this.qjsOverride, this.stampOverride});

  /// Tests / the smoke tool can point at binaries that are already on disk.
  final String? exeOverride;
  final String? qjsOverride;
  final String? stampOverride;

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
        // Without this the Windows build writes in the system code page. It ignores PYTHONUTF8 and friends.
        '--encoding', 'utf-8',
        '--no-js-runtimes',
        if (js) ...['--js-runtimes', 'quickjs:$_qjs'],
        ...args,
      ],
    );
    final out = StringBuffer();
    final err = StringBuffer();
    // Lenient: a stray byte must never replace yt-dlp's own answer with a decoding error.
    const decoder = Utf8Decoder(allowMalformed: true);
    final done = Future.wait([
      proc.stdout.transform(decoder).forEach(out.write),
      proc.stderr.transform(decoder).forEach(err.write),
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
      throw YtException(code == -1 ? 'yt-dlp timed out' : explainYtError(msg));
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

  /// Updates yt-dlp when the last successful update was more than [every] ago. Returns whether it ran.
  /// A failure (for example offline) is thrown and tried again next time.
  Future<bool> updateIfDue({Duration every = const Duration(hours: 24)}) async {
    await init();
    // Next to the binary; its modification time is when the last update succeeded.
    final stamp = File(stampOverride ?? p.join(p.dirname(_exe!), '.last-update'));
    if (await stamp.exists() && DateTime.now().difference(await stamp.lastModified()) < every) return false;
    await update();
    await stamp.writeAsString(DateTime.now().toIso8601String());
    return true;
  }

  @override
  Future<String> version() async => (await run(['--version'])).trim();
}
