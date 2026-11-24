import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../yt/yt_service.dart';

/// Optional on-disk audio cache: songs that were played once can be replayed offline.
/// Files are named `<videoId>.<ext>`; the oldest-used files are removed when the folder grows past the limit.
class CacheManager {
  CacheManager(this.dir, this.yt);

  final Directory dir;
  final YtService yt;
  final _downloading = <String, Future<void>>{};

  Future<void> _ensure() => dir.create(recursive: true);

  /// The cached file for [videoId], or null. Marks it as just used.
  Future<File?> lookup(String videoId) async {
    if (!await dir.exists()) return null;
    await for (final e in dir.list()) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      if (name.startsWith('$videoId.') && !name.endsWith('.part') && !name.endsWith('.ytdl')) {
        if (await e.length() == 0) continue;
        try {
          await e.setLastModified(DateTime.now());
        } catch (_) {}
        return e;
      }
    }
    return null;
  }

  /// Download [videoId] in the background (once at a time per song), then trim the cache to [maxBytes].
  Future<void> store(String videoId, {required int maxBytes}) {
    return _downloading[videoId] ??= () async {
      try {
        await _ensure();
        if (await lookup(videoId) != null) return;
        await yt.download(videoId, dir.path);
        await trim(maxBytes);
      } catch (_) {
        // The cache is a bonus: a failed download must never disturb playback.
      } finally {
        _downloading.remove(videoId);
      }
    }();
  }

  Future<int> sizeBytes() async {
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final e in dir.list()) {
      if (e is File) total += await e.length();
    }
    return total;
  }

  /// Delete least recently used files until the folder is at most [maxBytes].
  Future<void> trim(int maxBytes) async {
    if (!await dir.exists()) return;
    final files = <(File, int, DateTime)>[];
    var total = 0;
    await for (final e in dir.list()) {
      if (e is! File) continue;
      final len = await e.length();
      total += len;
      files.add((e, len, await e.lastModified()));
    }
    if (total <= maxBytes) return;
    files.sort((a, b) => a.$3.compareTo(b.$3));
    for (final f in files) {
      if (total <= maxBytes) break;
      try {
        await f.$1.delete();
        total -= f.$2;
      } catch (_) {}
    }
  }

  Future<void> clear() async {
    if (!await dir.exists()) return;
    await for (final e in dir.list()) {
      if (e is File) {
        try {
          await e.delete();
        } catch (_) {}
      }
    }
  }
}
