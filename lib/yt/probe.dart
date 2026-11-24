import 'dart:async';
import 'dart:io';

import 'models.dart';

/// Checks that a resolved stream URL really serves audio, by asking for its first two bytes.
/// YouTube sometimes hands out links that answer HTTP 403 (for example when a challenge was solved wrongly),
/// and finding out at resolve time is much better than finding out when the player stalls.
typedef StreamProbe = Future<bool> Function(ResolvedStream stream);

Future<bool> probeStream(ResolvedStream s) async {
  // Links that only start working a few seconds from now can't be judged yet.
  if (s.availableAt != null && s.availableAt!.isAfter(DateTime.now())) return true;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client.getUrl(Uri.parse(s.url));
    s.headers.forEach(req.headers.set);
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1');
    final res = await req.close().timeout(const Duration(seconds: 10));
    await res.drain<void>();
    return res.statusCode == HttpStatus.partialContent || res.statusCode == HttpStatus.ok;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}
