// Real yt-dlp against real YouTube. Skipped unless SMOKE=1.
//
//   SMOKE=1 YTDLP=/path/to/yt-dlp QJS=/path/to/qjs flutter test test/smoke_test.dart
//
// (defaults to the binaries in assets/bin/linux)
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tunes404/yt/backend_desktop.dart';
import 'package:tunes404/yt/ytdlp_service.dart';

void main() {
  final on = Platform.environment['SMOKE'] == '1';
  final exe = Platform.environment['YTDLP'] ?? 'assets/bin/linux/yt-dlp';
  final qjs = Platform.environment['QJS'] ?? 'assets/bin/linux/qjs';

  group('real yt-dlp through DesktopBackend + YtDlpService', skip: on ? false : 'set SMOKE=1', () {
    late YtDlpService yt;
    setUpAll(() => yt = YtDlpService(DesktopBackend(exeOverride: exe, qjsOverride: qjs)));

    test('version', () async => expect(await yt.version(), matches(RegExp(r'^\d{4}\.\d{2}\.\d{2}'))));

    test('search -> resolve -> stream answers a Range request', () async {
      final results = await yt.search('daft punk around the world');
      expect(results.length, greaterThan(3));
      final stream = await yt.resolve(results.first.id);
      expect(stream.isFresh, isTrue);
      final client = HttpClient();
      try {
        final req = await client.getUrl(Uri.parse(stream.url));
        stream.headers.forEach(req.headers.set);
        req.headers.set('Range', 'bytes=0-4095');
        final res = await req.close();
        final bytes = await res.fold<int>(0, (n, c) => n + c.length);
        expect(res.statusCode, 206);
        expect(bytes, 4096);
      } finally {
        client.close();
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('playlist search and expansion', () async {
      final lists = await yt.searchPlaylists('lofi hip hop');
      expect(lists, isNotEmpty);
      final p = await yt.playlist(lists.first.listId);
      expect(p.items, isNotEmpty);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('download writes an audio file', () async {
      final dir = Directory.systemTemp.createTempSync('tunes_dl');
      try {
        final path = await yt.download('dQw4w9WgXcQ', dir.path);
        expect(File(path).existsSync(), isTrue);
        expect(File(path).lengthSync(), greaterThan(100000));
      } finally {
        dir.deleteSync(recursive: true);
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('unknown video gives a readable error, not a hang', () async {
      await expectLater(yt.resolve('zzzzzzzzzzz'), throwsA(anything));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
