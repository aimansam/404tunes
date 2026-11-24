import 'package:flutter/services.dart';

import 'backend.dart';
import 'models.dart';

/// Android: yt-dlp runs inside the app through the youtubedl-android library
/// (see android/.../YtDlpPlugin.kt). The Kotlin side adds the JS-runtime arguments.
class AndroidBackend implements YtBackend {
  static const _ch = MethodChannel('dev.tunes404/ytdlp');
  Future<void>? _init;

  @override
  Future<void> init() => _init ??= _call<void>('init');

  Future<T?> _call<T>(String method, [Object? args]) async {
    try {
      return await _ch.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw YtException(e.message ?? e.code);
    }
  }

  @override
  Future<String> run(List<String> args,
      {Duration timeout = const Duration(seconds: 120), bool js = true}) async {
    await init();
    final out = await _call<String>(
        'run', {'args': args, 'timeoutMs': timeout.inMilliseconds, 'js': js});
    return out ?? '';
  }

  @override
  Future<String> update() async {
    await init();
    await _call<String>('update');
    return version();
  }

  @override
  Future<String> version() async {
    await init();
    return (await _call<String>('version')) ?? '';
  }
}
