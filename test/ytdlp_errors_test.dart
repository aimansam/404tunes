import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tunes404/yt/backend_desktop.dart';
import 'package:tunes404/yt/models.dart';

void main() {
  test('the bot check is explained, other errors are left alone', () {
    expect(explainYtError('ERROR: [youtube] abc: Sign in to confirm you’re not a bot. Use --cookies'),
        contains('cookies file in Settings'));
    expect(explainYtError('ERROR: [youtube] abc: Video unavailable'), 'ERROR: [youtube] abc: Video unavailable');
  });

  group('desktop yt-dlp output', () {
    late Directory dir;
    late DesktopBackend backend;
    late File exe;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('ytu404');
      exe = File('${dir.path}/yt-dlp');
      backend = DesktopBackend(exeOverride: exe.path, qjsOverride: '/bin/true');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    /// A stand-in for yt-dlp. In [body], `\222` is the byte a Windows code page uses for ’ (not valid UTF-8).
    Future<void> script(String body) async {
      await exe.writeAsString('#!/bin/sh\n$body\n');
      await Process.run('chmod', ['755', exe.path]);
    }

    test('asks for UTF-8', () async {
      await script('echo "\$@"');
      expect(await backend.run(['--version']), startsWith('--encoding utf-8 '));
    });

    test('an error that is not UTF-8 still arrives', () async {
      await script("printf 'ERROR: [youtube] Lufa9QAFFeY: Sign in to confirm you\\222re not a bot.\\n' >&2; exit 1");
      await expectLater(backend.run([]),
          throwsA(isA<YtException>().having((e) => e.message, 'message', contains('not a bot. Add or renew'))));
    });

    test('output that is not UTF-8 does not throw', () async {
      await script("printf 'ROS\\311\\n'");
      expect(await backend.run([]), 'ROS�\n');
    });
  }, skip: Platform.isWindows ? 'uses a shell script as a stand-in for yt-dlp' : false);
}
