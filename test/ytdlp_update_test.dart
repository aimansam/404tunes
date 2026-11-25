import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tunes404/yt/backend_desktop.dart';
import 'package:tunes404/yt/models.dart';

void main() {
  if (Platform.isWindows) return; // uses a shell script as a stand-in for yt-dlp

  test('desktop yt-dlp updates once a day and retries after a failure', () async {
    final dir = Directory.systemTemp.createTempSync('ytu404');
    addTearDown(() => dir.deleteSync(recursive: true));
    final exe = File('${dir.path}/yt-dlp');
    final log = File('${dir.path}/log');
    Future<void> script({required int exit}) async {
      await exe.writeAsString('#!/bin/sh\necho "\$@" >> "${log.path}"\ncase "\$*" in -U) exit $exit;; esac\necho 2026.01.01\n');
      await Process.run('chmod', ['755', exe.path]);
    }

    int updates() => log.existsSync() ? log.readAsLinesSync().where((l) => l == '-U').length : 0;
    final stamp = File('${dir.path}/stamp');
    final backend = DesktopBackend(exeOverride: exe.path, qjsOverride: '/bin/true', stampOverride: stamp.path);

    await script(exit: 1);
    await expectLater(backend.updateIfDue(), throwsA(isA<YtException>()));
    expect(stamp.existsSync(), isFalse); // tried again next time

    await script(exit: 0);
    expect(await backend.updateIfDue(), isTrue);
    expect(await backend.updateIfDue(), isFalse);
    expect(updates(), 2);

    stamp.setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 25)));
    expect(await backend.updateIfDue(), isTrue);
    expect(updates(), 3);
  });
}
