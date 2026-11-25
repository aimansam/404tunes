import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/services.dart';

import 'installer.dart';

/// Android: hands the downloaded APK to the system installer (see MainActivity.kt). Android only accepts it when it
/// is signed with the same key as the installed app.
class AndroidInstaller implements UpdateInstaller {
  AndroidInstaller({Abi? abi}) : _abi = abi ?? Abi.current();
  final Abi _abi;

  static const _channel = MethodChannel('dev.tunes404/update');

  @override
  String? get assetName => switch (_abi) {
        Abi.androidArm64 => 'app-arm64-v8a-release.apk',
        Abi.androidArm => 'app-armeabi-v7a-release.apk',
        Abi.androidX64 => 'app-x86_64-release.apk',
        _ => null,
      };

  @override
  Future<InstallResult> install(File file) async {
    final r = await _channel.invokeMethod<String>('install', {'path': file.path});
    return r == 'needs_permission' ? InstallResult.needsPermission : InstallResult.handedToSystem;
  }

  @override
  Future<void> openPage(Uri page) => _channel.invokeMethod<void>('open', {'url': page.toString()});
}
