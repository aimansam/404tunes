import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import 'update_key.dart';
import 'version.dart';

class UpdateException implements Exception {
  UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The user stopped a download.
class UpdateCancelled implements Exception {}

class CancelToken {
  bool cancelled = false;
  void cancel() => cancelled = true;
}

/// A GitHub release that is newer than the running app.
class ReleaseInfo {
  const ReleaseInfo({required this.version, required this.notes, required this.page, required this.assets});
  final Version version;
  final String notes;
  final Uri page;

  /// File name to download link.
  final Map<String, Uri> assets;
}

/// Release notes as plain text: the app shows them without a Markdown renderer.
String plainNotes(String markdown) => markdown
    .replaceAll('\r', '')
    .split('\n')
    .where((l) => !l.startsWith('**Full Changelog**')) // GitHub's auto-generated compare link
    .map((l) => l.replaceFirst(RegExp(r'^#{1,6}\s+'), '').replaceAll('**', ''))
    .join('\n')
    .trim();

const manifestName = 'update.json';
const signatureName = 'update.json.sig';

/// Finds newer releases on GitHub and downloads them. A download is only accepted when the release's `update.json`
/// is signed with the project's key (see tool/sign_update.sh) and the file matches the size and SHA-256 in it.
class Updater {
  Updater({
    required this.currentVersion,
    http.Client? client,
    this.publicKey = updatePublicKey,
    this.repo = 'aimansam/404tunes',
    this.requestTimeout = const Duration(seconds: 20),
    this.stallTimeout = const Duration(seconds: 60),
  }) : _client = client ?? http.Client();

  /// Null in builds that were not made from a release tag; those never update.
  final Version? currentVersion;
  final String publicKey;
  final String repo;
  final Duration requestTimeout, stallTimeout;
  final http.Client _client;

  static const _headers = {'User-Agent': '404tunes-updater'};

  /// The latest release if it is newer than this app, otherwise null.
  Future<ReleaseInfo?> check() async {
    final current = currentVersion;
    if (current == null) return null;
    final http.Response r;
    try {
      r = await _client.get(Uri.https('api.github.com', '/repos/$repo/releases/latest'),
          headers: {..._headers, 'Accept': 'application/vnd.github+json'}).timeout(requestTimeout);
    } catch (_) {
      throw UpdateException('Could not reach GitHub. Check your internet connection.');
    }
    if (r.statusCode == 404) return null; // no releases yet
    if (r.statusCode == 403 || r.statusCode == 429) throw UpdateException('GitHub is busy. Try again in an hour.');
    if (r.statusCode != 200) throw UpdateException('GitHub answered with error ${r.statusCode}');
    try {
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      final tag = j['tag_name'] as String;
      final v = Version.tryParse(tag);
      if (v == null || !(v > current)) return null;
      return ReleaseInfo(
        version: v,
        notes: plainNotes((j['body'] as String?) ?? ''),
        // Built here, not taken from the answer: this link gets opened in the browser.
        page: Uri.https('github.com', '/$repo/releases/tag/$tag'),
        assets: {
          for (final a in (j['assets'] as List).cast<Map<String, dynamic>>())
            if (Uri.tryParse(a['browser_download_url'] as String)?.scheme == 'https')
              a['name'] as String: Uri.parse(a['browser_download_url'] as String),
        },
      );
    } catch (_) {
      throw UpdateException('GitHub sent an answer this app does not understand');
    }
  }

  Future<List<int>> _small(ReleaseInfo release, String name) async {
    final url = release.assets[name];
    if (url == null) throw UpdateException('This release cannot be verified. Download it from the release page.');
    final http.Response r;
    try {
      r = await _client.get(url, headers: _headers).timeout(requestTimeout);
    } catch (_) {
      throw UpdateException('The download failed. Check your internet connection.');
    }
    if (r.statusCode != 200 || r.bodyBytes.length > 64 * 1024) throw UpdateException('The download failed (${r.statusCode})');
    return r.bodyBytes;
  }

  /// Size and SHA-256 of [assetName], taken from the release's manifest after checking its signature.
  Future<({int size, String sha256})> _expected(ReleaseInfo release, String assetName) async {
    final manifest = await _small(release, manifestName);
    final signature = await _small(release, signatureName);
    var trusted = false;
    try {
      trusted = await Ed25519().verify(
        manifest,
        signature: Signature(
          base64Decode(utf8.decode(signature).trim()),
          publicKey: SimplePublicKey(base64Decode(publicKey), type: KeyPairType.ed25519),
        ),
      );
    } catch (_) {} // malformed signature: not trusted
    if (!trusted) throw UpdateException('The update signature is not valid, so it was not installed.');
    try {
      final j = jsonDecode(utf8.decode(manifest)) as Map<String, dynamic>;
      // An old, correctly signed manifest must not pass for a new release.
      if (Version.tryParse(j['version'] as String) != release.version) {
        throw UpdateException('The update manifest belongs to another version.');
      }
      final f = (j['files'] as Map<String, dynamic>)[assetName] as Map<String, dynamic>;
      return (size: f['size'] as int, sha256: (f['sha256'] as String).toLowerCase());
    } on UpdateException {
      rethrow;
    } catch (_) {
      throw UpdateException('This release has no verified file for this device.');
    }
  }

  /// Downloads [assetName] into [dir] (which is emptied first) and returns it once it has been verified.
  Future<File> download(
    ReleaseInfo release,
    String assetName,
    Directory dir, {
    void Function(double fraction)? onProgress,
    CancelToken? cancel,
  }) async {
    final expected = await _expected(release, assetName);
    final url = release.assets[assetName];
    if (url == null) throw UpdateException('This release has no file for this device.');

    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final part = File('${dir.path}${Platform.pathSeparator}$assetName.part');
    try {
      final http.StreamedResponse r = await _client.send(http.Request('GET', url)..headers.addAll(_headers)).timeout(requestTimeout);
      if (r.statusCode != 200) throw UpdateException('The download failed (${r.statusCode})');
      final hasher = Sha256().newHashSink();
      final out = part.openWrite();
      var received = 0;
      try {
        await for (final chunk in r.stream.timeout(stallTimeout)) {
          if (cancel?.cancelled ?? false) throw UpdateCancelled();
          received += chunk.length;
          if (received > expected.size) throw UpdateException('The download is larger than it should be, so it was discarded.');
          out.add(chunk);
          hasher.add(chunk);
          onProgress?.call(received / expected.size);
        }
      } finally {
        await out.close();
      }
      if (cancel?.cancelled ?? false) throw UpdateCancelled();
      hasher.close();
      final digest = (await hasher.hash()).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      if (received != expected.size || digest != expected.sha256) {
        throw UpdateException('The downloaded file is damaged, so it was not installed. Try again.');
      }
      return await part.rename('${dir.path}${Platform.pathSeparator}$assetName');
    } catch (e) {
      if (await part.exists()) await part.delete();
      if (e is UpdateException || e is UpdateCancelled) rethrow;
      throw UpdateException('The download failed. Check your internet connection.');
    }
  }
}
