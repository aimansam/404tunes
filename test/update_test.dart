import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tunes404/settings.dart';
import 'package:tunes404/update/installer.dart';
import 'package:tunes404/update/installer_android.dart';
import 'package:tunes404/update/update_controller.dart';
import 'package:tunes404/update/updater.dart';
import 'package:tunes404/update/version.dart';

const asset = DesktopInstaller.windowsSetup;

/// A pretend GitHub with one release, signed like tool/sign_update.sh signs it.
class FakeGitHub {
  FakeGitHub._(this._key, this.publicKey);
  final SimpleKeyPair _key;
  final String publicKey;

  String tag = 'v1.1.0';
  List<int> file = utf8.encode('the new installer ' * 500);
  List<int>? served; // what the download really returns, when different from [file]
  String? manifestVersion;
  List<int>? manifest, signature;
  bool offline = false;
  bool publishManifest = true;
  int status = 200;
  final requests = <Uri>[];

  static Future<FakeGitHub> create() async {
    final key = await Ed25519().newKeyPair();
    return FakeGitHub._(key, base64Encode((await key.extractPublicKey()).bytes));
  }

  Future<void> sign({SimpleKeyPair? key}) async {
    final hash = (await Sha256().hash(file)).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    manifest = utf8.encode(jsonEncode({
      'version': manifestVersion ?? tag.substring(1),
      'files': {
        asset: {'size': file.length, 'sha256': hash}
      },
    }));
    signature = utf8.encode(base64Encode((await Ed25519().sign(manifest!, keyPair: key ?? _key)).bytes));
  }

  http.Client get client => MockClient((r) async {
        requests.add(r.url);
        if (offline) throw const SocketException('offline');
        if (r.url.host == 'api.github.com') {
          return http.Response(
              jsonEncode({
                'tag_name': tag,
                'body': 'Notes for $tag',
                'html_url': 'https://evil.example/',
                'assets': [
                  for (final n in [asset, if (publishManifest) ...[manifestName, signatureName]])
                    {'name': n, 'browser_download_url': 'https://github.com/dl/$n'}
                ],
              }),
              status);
        }
        final name = r.url.pathSegments.last;
        if (name == manifestName) return http.Response.bytes(manifest!, 200);
        if (name == signatureName) return http.Response.bytes(signature!, 200);
        return http.Response.bytes(served ?? file, 200);
      });

  Updater updater({String? current = '1.0.0'}) =>
      Updater(currentVersion: current == null ? null : Version.tryParse(current), client: client, publicKey: publicKey);
}

class FakeInstaller implements UpdateInstaller {
  String? name = asset;
  InstallResult result = InstallResult.restarting;
  final installed = <String>[];
  final opened = <Uri>[];
  @override
  String? get assetName => name;
  @override
  Future<InstallResult> install(File file) async {
    installed.add(await file.readAsString());
    return result;
  }

  @override
  Future<void> openPage(Uri page) async => opened.add(page);
}

void main() {
  late FakeGitHub gh;
  late Directory tmp;

  setUp(() async {
    gh = await FakeGitHub.create();
    await gh.sign();
    tmp = Directory.systemTemp.createTempSync('upd404');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Directory downloads() => Directory('${tmp.path}/dl');
  List<String> downloaded() => downloads().existsSync() ? downloads().listSync().map((f) => f.uri.pathSegments.last).toList() : [];

  group('versions', () {
    test('parses release tags and compares by number, not by text', () {
      expect(Version.tryParse('v1.2.3'), const Version(1, 2, 3));
      expect(Version.tryParse('0.10.0')! > Version.tryParse('0.9.9')!, isTrue);
      expect(Version.tryParse('1.0.0')! > Version.tryParse('1.0.0')!, isFalse);
      for (final bad in ['', 'v1', '1.2', '1.2.3-beta', 'v1.2.3 ', 'latest']) {
        expect(Version.tryParse(bad), isNull, reason: bad);
      }
    });
  });

  test('release notes are shown as plain text', () {
    expect(plainNotes('## What\'s new\r\n- **Faster** search\r\n\r\n**Full Changelog**: https://github.com/x/y/compare/a...b'),
        'What\'s new\n- Faster search');
    expect(plainNotes('**Full Changelog**: https://github.com/x/y/compare/a...b'), '');
  });

  group('check', () {
    test('offers only a newer release, with a page link built by the app', () async {
      final r = await gh.updater().check();
      expect(r!.version, const Version(1, 1, 0));
      expect(r.notes, 'Notes for v1.1.0');
      expect(r.page.toString(), 'https://github.com/aimansam/404tunes/releases/tag/v1.1.0');
      expect(await gh.updater(current: '1.1.0').check(), isNull);
      expect(await gh.updater(current: '2.0.0').check(), isNull);
    });

    test('ignores odd tags and a repo without releases', () async {
      gh.tag = 'v2.0.0-rc1';
      expect(await gh.updater().check(), isNull);
      gh.status = 404;
      expect(await gh.updater().check(), isNull);
    });

    test('reports being offline or rate limited', () async {
      gh.status = 403;
      await expectLater(gh.updater().check(), throwsA(isA<UpdateException>().having((e) => e.message, 'message', contains('busy'))));
      gh.offline = true;
      await expectLater(gh.updater().check(), throwsA(isA<UpdateException>()));
    });

    test('a development build never asks', () async {
      expect(await gh.updater(current: null).check(), isNull);
      expect(gh.requests, isEmpty);
    });
  });

  group('download', () {
    Future<File> get() async {
      final u = gh.updater();
      return u.download((await u.check())!, asset, downloads());
    }

    Future<void> refused(String because) async {
      await expectLater(get(), throwsA(isA<UpdateException>().having((e) => e.message, 'message', contains(because))));
      expect(downloaded(), isEmpty, reason: 'nothing may be left behind');
    }

    test('returns the verified file and reports progress', () async {
      final u = gh.updater();
      final progress = <double>[];
      downloads().createSync();
      File('${downloads().path}/old-download').writeAsStringSync('x');
      final f = await u.download((await u.check())!, asset, downloads(), onProgress: progress.add);
      expect(await f.readAsBytes(), gh.file);
      expect(progress.last, 1.0);
      expect(downloaded(), [asset]); // the old one is gone
    });

    test('refuses a manifest signed with another key', () async {
      await gh.sign(key: await Ed25519().newKeyPair());
      await refused('signature');
      expect(gh.requests.where((u) => u.pathSegments.last == asset), isEmpty, reason: 'not even downloaded');
    });

    test('refuses a changed manifest, a broken signature and a release without them', () async {
      gh.manifest = [...gh.manifest!, 32];
      await refused('signature');
      await gh.sign();
      gh.signature = utf8.encode('not base64 !!');
      await refused('signature');
      gh.publishManifest = false;
      await refused('cannot be verified');
    });

    test('refuses an old signed manifest presented as a newer release', () async {
      gh.manifestVersion = '1.0.5';
      await gh.sign();
      await refused('another version');
    });

    test('refuses a file that was swapped, grew or is cut short', () async {
      gh.served = List.of(gh.file)..[10] ^= 1;
      await refused('damaged');
      gh.served = [...gh.file, 1, 2, 3];
      await refused('larger');
      gh.served = gh.file.sublist(0, 100);
      await refused('damaged');
    });

    test('refuses a device that the manifest has no file for', () async {
      final u = gh.updater();
      await expectLater(u.download((await u.check())!, 'other.apk', downloads()), throwsA(isA<UpdateException>()));
    });

    test('can be cancelled', () async {
      final u = gh.updater();
      final cancel = CancelToken()..cancel();
      await expectLater(u.download((await u.check())!, asset, downloads(), cancel: cancel), throwsA(isA<UpdateCancelled>()));
      expect(downloaded(), isEmpty);
    });

    test('accepts a signature made by openssl, as the release workflow makes it', () async {
      const dir = 'test/fixtures/update';
      final ok = await Ed25519().verify(
        File('$dir/manifest.json').readAsBytesSync(),
        signature: Signature(base64Decode(File('$dir/manifest.sig').readAsStringSync()),
            publicKey: SimplePublicKey(base64Decode(File('$dir/public.txt').readAsStringSync()), type: KeyPairType.ed25519)),
      );
      expect(ok, isTrue);
      final u = Updater(
        currentVersion: const Version(1, 0, 0),
        publicKey: File('$dir/public.txt').readAsStringSync(),
        client: MockClient((r) async => switch (r.url.pathSegments.last) {
              manifestName => http.Response.bytes(File('$dir/manifest.json').readAsBytesSync(), 200),
              signatureName => http.Response.bytes(File('$dir/manifest.sig').readAsBytesSync(), 200),
              _ => http.Response('abc', 200),
            }),
      );
      final release = ReleaseInfo(version: const Version(9, 9, 9), notes: '', page: Uri(), assets: {
        for (final n in ['a.bin', manifestName, signatureName]) n: Uri.parse('https://github.com/dl/$n')
      });
      expect(await (await u.download(release, 'a.bin', downloads())).readAsString(), 'abc');
    });
  });

  group('desktop installer', () {
    final started = <(String, List<String>)>[];
    final order = <String>[];
    DesktopInstaller installer(String os, {bool setup = false}) {
      if (setup) File('${tmp.path}/unins000.exe').writeAsStringSync('');
      return DesktopInstaller(
        operatingSystem: os,
        executable: '${tmp.path}/tunes404.exe',
        quit: () async => order.add('quit'),
        start: (e, a) async {
          started.add((e, a));
          order.add('start');
        },
      );
    }

    setUp(() {
      started.clear();
      order.clear();
    });

    test('only a Windows copy made by the installer updates itself', () {
      expect(installer('windows').assetName, isNull); // portable zip
      expect(installer('windows', setup: true).assetName, asset);
      expect(installer('linux', setup: true).assetName, isNull);
      expect(installer('macos').assetName, isNull);
    });

    test('starts the setup silently, asks it to relaunch, then quits', () async {
      final r = await installer('windows', setup: true).install(File('C:/tmp/setup.exe'));
      expect(r, InstallResult.restarting);
      expect(order, ['start', 'quit']);
      expect(started.single.$1, 'C:/tmp/setup.exe');
      expect(started.single.$2, containsAll(['/SILENT', '/RELAUNCH=1', '/CLOSEAPPLICATIONS']));
    });

    test('opens only GitHub pages', () async {
      final page = Uri.parse('https://github.com/aimansam/404tunes/releases/tag/v1.1.0');
      await installer('linux').openPage(page);
      expect(started.single.$1, 'xdg-open');
      expect(started.single.$2, [page.toString()]);
      await expectLater(installer('linux').openPage(Uri.parse('https://evil.example/x')), throwsArgumentError);
      await expectLater(installer('linux').openPage(Uri.parse('file:///etc/passwd')), throwsArgumentError);
    });
  });

  test('Android picks the APK for the processor and passes on the permission answer', () async {
    expect(AndroidInstaller(abi: Abi.androidArm64).assetName, 'app-arm64-v8a-release.apk');
    expect(AndroidInstaller(abi: Abi.androidArm).assetName, 'app-armeabi-v7a-release.apk');
    expect(AndroidInstaller(abi: Abi.androidX64).assetName, 'app-x86_64-release.apk');
    expect(AndroidInstaller(abi: Abi.androidIA32).assetName, isNull);
    TestWidgetsFlutterBinding.ensureInitialized();
    var answer = 'needs_permission';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('dev.tunes404/update'), (c) async => answer);
    expect(await AndroidInstaller().install(File('x.apk')), InstallResult.needsPermission);
    answer = 'started';
    expect(await AndroidInstaller().install(File('x.apk')), InstallResult.handedToSystem);
  });

  group('controller', () {
    late FakeInstaller installer;
    late AppSettings settings;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = await AppSettings.load();
      installer = FakeInstaller();
    });

    UpdateController controller({String? current = '1.0.0'}) => UpdateController(
        updater: gh.updater(current: current), installer: installer, settings: settings, downloadDir: () async => downloads());

    test('shows a banner for a new version until "Later", and again for the next one', () async {
      final c = controller();
      await c.check();
      expect(c.phase, UpdatePhase.available);
      expect(c.showBanner, isTrue);
      await c.dismiss();
      expect(c.showBanner, isFalse);
      expect(c.release, isNotNull); // Settings still offers it
      gh.tag = 'v1.2.0';
      await c.check();
      expect(c.showBanner, isTrue);
    });

    test('downloads, verifies and installs', () async {
      final c = controller();
      await c.check();
      await c.update();
      expect(installer.installed, [utf8.decode(gh.file)]);
      expect(c.phase, UpdatePhase.installing);
    });

    test('never installs a download that fails verification', () async {
      gh.served = List.of(gh.file)..[0] ^= 1;
      final c = controller();
      await c.check();
      await c.update();
      expect(installer.installed, isEmpty);
      expect(c.phase, UpdatePhase.available);
      expect(c.error, contains('damaged'));
    });

    test('after the Android permission screen, Install reuses the download', () async {
      installer.result = InstallResult.needsPermission;
      final c = controller();
      await c.check();
      await c.update();
      expect((c.phase, c.needsPermission), (UpdatePhase.ready, true));
      installer.result = InstallResult.handedToSystem;
      await c.update();
      expect(installer.installed, hasLength(2));
      expect(gh.requests.where((u) => u.pathSegments.last == asset), hasLength(1));
      expect(c.needsPermission, isFalse);
    });

    test('where it cannot install, it opens the release page and downloads nothing', () async {
      installer.name = null;
      final c = controller();
      await c.check();
      expect(c.canInstall, isFalse);
      await c.update();
      expect(installer.opened.single.path, endsWith('/v1.1.0'));
      expect(gh.requests, hasLength(1));
    });

    test('a later failed check keeps the update that was already found', () async {
      final c = controller();
      await c.check();
      gh.offline = true;
      await c.check();
      expect((c.phase, c.release?.version), (UpdatePhase.available, const Version(1, 1, 0)));
      expect(c.error, isNotNull);
    });

    test('the daily check obeys the setting; the button still works', () async {
      await settings.setAutoUpdateCheck(false);
      final c = controller()..start(delay: Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(gh.requests, isEmpty);
      await c.check();
      expect(gh.requests, hasLength(1));
      await settings.setAutoUpdateCheck(true);
      final c2 = controller()..start(delay: Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(c2.release, isNotNull);
      c.dispose();
      c2.dispose();
    });

    test('is off in development builds', () async {
      final c = controller(current: null)..start(delay: Duration.zero);
      await c.check();
      expect(c.enabled, isFalse);
      expect(gh.requests, isEmpty);
    });
  });
}
