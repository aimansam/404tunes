import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tunes404/settings.dart';
import 'package:tunes404/ui/update_ui.dart';
import 'package:tunes404/update/installer.dart';
import 'package:tunes404/update/update_controller.dart';
import 'package:tunes404/update/updater.dart';
import 'package:tunes404/update/version.dart';

class NoInstaller implements UpdateInstaller {
  @override
  String? get assetName => null;
  @override
  Future<InstallResult> install(File file) async => throw UnimplementedError();
  final opened = <Uri>[];
  @override
  Future<void> openPage(Uri page) async => opened.add(page);
}

void main() {
  testWidgets('banner on a phone-sized screen leads to the notes and the download page; Later hides it', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final installer = NoInstaller();
    final c = UpdateController(
      updater: Updater(
        currentVersion: const Version(1, 0, 0),
        client: MockClient((_) async => http.Response('{"tag_name":"v1.1.0","body":"Better playback","assets":[]}', 200)),
      ),
      installer: installer,
      settings: await AppSettings.load(),
      downloadDir: () async => Directory.systemTemp,
    );
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Column(children: [UpdateBanner(updates: c)]))));
    expect(find.textContaining('available'), findsNothing);

    await tester.runAsync(c.check);
    await tester.pumpAndSettle();
    expect(find.text('404 Tunes 1.1.0 is available'), findsOneWidget);

    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
    expect(find.text('Better playback'), findsOneWidget);
    await tester.tap(find.text('Open download page'));
    await tester.pumpAndSettle();
    expect(installer.opened.single.host, 'github.com');
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    expect(find.textContaining('is available'), findsNothing);
    expect(tester.takeException(), isNull); // nothing overflowed
  });
}
