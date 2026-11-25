import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tunes404/player/cache_manager.dart';
import 'package:tunes404/yt/backend.dart';
import 'package:tunes404/yt/models.dart';
import 'package:tunes404/yt/ytdlp_service.dart';

String fixtureText(String name) => File('test/fixtures/$name').readAsStringSync();

/// Pretends to be yt-dlp: answers from fixtures and records every call.
class FakeBackend implements YtBackend {
  final calls = <List<String>>[];
  final jsFlags = <bool>[];
  Duration delay = Duration.zero;
  Object? failWith;
  Object? failWithoutJs; // errors only when yt-dlp runs without the JS runtime
  bool blankChannelsOnce = false; // the next search answers without channel names, like YouTube sometimes does

  @override
  Future<void> init() async {}

  @override
  Future<String> run(List<String> args,
      {Duration timeout = const Duration(seconds: 120), bool js = true}) async {
    calls.add(args);
    jsFlags.add(js);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (failWith != null) throw failWith!;
    if (!js && failWithoutJs != null) throw failWithoutJs!;
    final url = args.last;
    if (url.startsWith('ytsearch')) {
      final text = fixtureText('search.json');
      if (blankChannelsOnce) {
        blankChannelsOnce = false;
        final j = jsonDecode(text) as Map<String, dynamic>;
        for (final e in j['entries'] as List) {
          (e as Map<String, dynamic>)..remove('channel')..remove('uploader');
        }
        return jsonEncode(j);
      }
      return text;
    }
    if (url.contains('/results?')) return fixtureText('playlist_search.json');
    if (url.contains('/playlist?')) return fixtureText('playlist.json');
    if (url.contains('/watch?')) {
      if (args.contains('-o')) return '${args[args.indexOf('-o') + 1].replaceAll('%(ext)s', 'webm')}\n';
      return fixtureText('resolve.json');
    }
    if (args.contains('--version')) return '2026.01.01\n';
    throw StateError('unexpected call $args');
  }

  @override
  Future<String> update() async => '2026.02.02';

  @override
  Future<String> version() async => '2026.01.01';
}

void main() {
  late FakeBackend be;
  late YtDlpService yt;
  var now = DateTime(2026, 1, 1, 12);
  var probeOk = true;
  var probed = 0;

  setUp(() {
    be = FakeBackend();
    now = DateTime(2026, 1, 1, 12);
    probeOk = true;
    probed = 0;
    yt = YtDlpService(be, clock: () => now, probe: (s) async {
      probed++;
      return probeOk;
    });
  });

  test('search runs yt-dlp once and caches for 10 minutes', () async {
    final a = await yt.search('Lo-Fi');
    expect(a, isNotEmpty);
    expect(be.calls, hasLength(1));
    expect(be.calls.single, containsAll(['-J', '--flat-playlist', 'ytsearch20:Lo-Fi']));
    await yt.search('lo-fi '); // same query ignoring case / spaces
    expect(be.calls, hasLength(1));
    now = now.add(const Duration(minutes: 11));
    await yt.search('lo-fi');
    expect(be.calls, hasLength(2));
  });

  test('a search answered without channel names is asked once more', () async {
    be.blankChannelsOnce = true;
    final r = await yt.search('Lo-Fi');
    expect(be.calls, hasLength(2));
    expect(r.where((t) => t.channel.isEmpty), isEmpty);
    expect(be.calls.length, 2);
    await yt.search('lo-fi'); // the better answer is what got cached
    expect(be.calls, hasLength(2));
  });

  test('empty search does nothing', () async {
    expect(await yt.search('   '), isEmpty);
    expect(be.calls, isEmpty);
  });

  test('a search term that looks like an option cannot become one', () async {
    await yt.search('--exec calc');
    final last = be.calls.single.last;
    expect(last, 'ytsearch20:--exec calc'); // always one argument with the ytsearch prefix
  });

  test('playlist search uses the YouTube results page with the playlist filter', () async {
    final r = await yt.searchPlaylists('study music');
    expect(r, isNotEmpty);
    expect(be.calls.single.last, contains('search_query=study%20music'.replaceAll('%20', '+')));
    expect(be.calls.single.last, contains('sp=EgIQAw%3D%3D'));
  });

  test('playlist: validates the id, caches 30 minutes', () async {
    await expectLater(yt.playlist('bad id!'), throwsA(isA<YtException>()));
    final p = await yt.playlist('PLFgquLnL59alCl_2TQvOiD5Vgm1hCaGSI');
    expect(p.items, isNotEmpty);
    await yt.playlist('PLFgquLnL59alCl_2TQvOiD5Vgm1hCaGSI');
    expect(be.calls, hasLength(1));
  });

  test('resolve: cached while fresh, fresh:true bypasses, expired link is looked up again', () async {
    final a = await yt.resolve('dQw4w9WgXcQ');
    await yt.resolve('dQw4w9WgXcQ');
    expect(be.calls, hasLength(1));
    expect(be.calls.single, containsAll(['-f', '--no-playlist']));
    await yt.resolve('dQw4w9WgXcQ', fresh: true);
    expect(be.calls, hasLength(2));
    now = a.expiresAt.add(const Duration(seconds: 1));
    await yt.resolve('dQw4w9WgXcQ');
    expect(be.calls, hasLength(3));
  });

  test('resolve: simultaneous requests for one song share one yt-dlp run', () async {
    be.delay = const Duration(milliseconds: 30);
    final results = await Future.wait([for (var i = 0; i < 5; i++) yt.resolve('dQw4w9WgXcQ')]);
    expect(be.calls, hasLength(1));
    expect(results.map((r) => r.url).toSet(), hasLength(1));
  });

  test('resolve: a failed lookup is not cached and can be retried', () async {
    be.failWith = YtException('Sign in to confirm');
    await expectLater(yt.resolve('dQw4w9WgXcQ'), throwsA(isA<YtException>()));
    be.failWith = null;
    expect((await yt.resolve('dQw4w9WgXcQ')).track.id, 'dQw4w9WgXcQ');
  });

  group('resolve strategy', () {
    test('fast path first: no JS runtime, link verified, one yt-dlp run', () async {
      await yt.resolve('dQw4w9WgXcQ');
      expect(be.jsFlags, [false]);
      expect(probed, 1);
    });

    test('a link that fails the check is looked up again with the JS runtime', () async {
      probeOk = false;
      final s = await yt.resolve('dQw4w9WgXcQ');
      expect(be.jsFlags, [false, true]);
      expect(s.track.id, 'dQw4w9WgXcQ');
    });

    test('yt-dlp failing without JS (formats missing) falls back to the JS runtime', () async {
      be.failWithoutJs = YtException('Requested format is not available');
      final s = await yt.resolve('dQw4w9WgXcQ');
      expect(be.jsFlags, [false, true]);
      expect(s.url, startsWith('https://'));
      expect(probed, 0);
    });

    test('when both paths fail the error reaches the caller', () async {
      be.failWith = YtException('Sign in to confirm');
      await expectLater(yt.resolve('dQw4w9WgXcQ'), throwsA(isA<YtException>()));
      expect(be.jsFlags, [false, true]);
    });

    test('searches and playlists never start the JS runtime', () async {
      await yt.search('x');
      await yt.searchPlaylists('x');
      await yt.playlist('PLFgquLnL59alCl_2TQvOiD5Vgm1hCaGSI');
      expect(be.jsFlags, everyElement(isFalse));
    });

    test('download tries without JS first and retries with it', () async {
      be.failWithoutJs = YtException('format not available');
      final dir = Directory.systemTemp.createTempSync('tunes_dl');
      addTearDown(() => dir.deleteSync(recursive: true));
      await yt.download('dQw4w9WgXcQ', dir.path);
      expect(be.jsFlags, [false, true]);
    });
  });

  test('resolve rejects ids that are not 11 chars', () {
    expect(() => yt.resolve('../etc'), throwsA(isA<YtException>()));
  });

  test('cookies are passed to yt-dlp only when set', () async {
    await yt.search('a');
    expect(be.calls.last, isNot(contains('--cookies')));
    yt.cookiesPath = '/tmp/c.txt';
    await yt.search('b');
    expect(be.calls.last, containsAllInOrder(['--cookies', '/tmp/c.txt']));
    yt.cookiesPath = null;
    await yt.search('c');
    expect(be.calls.last, isNot(contains('--cookies')));
  });

  test('update clears stream cache and returns the new version', () async {
    await yt.resolve('dQw4w9WgXcQ');
    expect(await yt.update(), '2026.02.02');
    await yt.resolve('dQw4w9WgXcQ');
    expect(be.calls.where((c) => c.contains('--no-playlist')), hasLength(2));
  });

  test('bad JSON from yt-dlp becomes a YtException', () async {
    final bad = _Raw('not json');
    final y = YtDlpService(bad);
    await expectLater(y.search('x'), throwsA(isA<YtException>()));
  });

  group('CacheManager', () {
    late Directory dir;
    late CacheManager cache;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('tunes_cache');
      cache = CacheManager(dir, yt);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    File put(String name, int bytes, DateTime modified) {
      final f = File('${dir.path}/$name')..writeAsBytesSync(List.filled(bytes, 1));
      f.setLastModifiedSync(modified);
      return f;
    }

    test('lookup finds a song by id and ignores partial files', () async {
      put('aaaaaaaaaaa.webm', 10, DateTime(2026));
      put('bbbbbbbbbbb.webm.part', 10, DateTime(2026));
      expect(await cache.lookup('aaaaaaaaaaa'), isNotNull);
      expect(await cache.lookup('bbbbbbbbbbb'), isNull);
      expect(await cache.lookup('ccccccccccc'), isNull);
    });

    test('trim removes the least recently used files first', () async {
      put('aaaaaaaaaaa.webm', 100, DateTime(2026, 1, 1));
      put('bbbbbbbbbbb.webm', 100, DateTime(2026, 1, 3));
      put('ccccccccccc.webm', 100, DateTime(2026, 1, 2));
      await cache.trim(200);
      expect(File('${dir.path}/aaaaaaaaaaa.webm').existsSync(), isFalse);
      expect(File('${dir.path}/bbbbbbbbbbb.webm').existsSync(), isTrue);
      expect(File('${dir.path}/ccccccccccc.webm').existsSync(), isTrue);
      expect(await cache.sizeBytes(), 200);
      await cache.trim(0);
      expect(await cache.sizeBytes(), 0);
    });

    test('playing a cached song marks it as recently used', () async {
      put('aaaaaaaaaaa.webm', 100, DateTime(2026, 1, 1));
      put('bbbbbbbbbbb.webm', 100, DateTime(2026, 1, 2));
      await cache.lookup('aaaaaaaaaaa'); // touched now
      await cache.trim(100);
      expect(File('${dir.path}/aaaaaaaaaaa.webm').existsSync(), isTrue);
      expect(File('${dir.path}/bbbbbbbbbbb.webm').existsSync(), isFalse);
    });

    test('store downloads once and swallows failures', () async {
      await cache.store('dQw4w9WgXcQ', maxBytes: 1 << 30);
      expect(be.calls.where((c) => c.contains('-o')), hasLength(1));
      be.failWith = YtException('offline');
      await cache.store('aaaaaaaaaaa', maxBytes: 1 << 30); // must not throw
    });
  });
}

class _Raw implements YtBackend {
  _Raw(this.out);
  final String out;
  @override
  Future<void> init() async {}
  @override
  Future<String> run(List<String> args,
          {Duration timeout = const Duration(seconds: 120), bool js = true}) async =>
      out;
  @override
  Future<String> update() async => '';
  @override
  Future<String> version() async => '';
}
