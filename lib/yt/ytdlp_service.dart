import 'dart:convert';
import 'dart:io';

import 'backend.dart';
import 'models.dart';
import 'parsers.dart';
import 'probe.dart';
import 'yt_service.dart';

class _Cached<T> {
  _Cached(this.value, this.expires);
  final T value;
  final DateTime expires;
}

/// The one `YtService` implementation: shared logic on top of a platform [YtBackend].
class YtDlpService implements YtService {
  YtDlpService(this.backend, {DateTime Function()? clock, StreamProbe? probe})
      : _now = clock ?? DateTime.now,
        _probe = probe ?? probeStream;

  final YtBackend backend;
  final DateTime Function() _now;
  final StreamProbe _probe;

  static const _searchTtl = Duration(minutes: 10);
  static const _listTtl = Duration(minutes: 30);
  static const _playlistFilter = 'EgIQAw%3D%3D'; // YouTube's "type: playlist" filter
  static const _audioFormat =
      'bestaudio[ext=webm]/bestaudio[ext=m4a]/bestaudio/best';

  String? _cookies;
  final _search = <String, _Cached<List<Track>>>{};
  final _plSearch = <String, _Cached<List<PlaylistResult>>>{};
  final _playlists = <String, _Cached<PlaylistContents>>{};
  final _streams = <String, ResolvedStream>{};
  final _inflight = <String, Future<ResolvedStream>>{};

  @override
  set cookiesPath(String? path) {
    _cookies = (path != null && path.isNotEmpty) ? path : null;
    _streams.clear(); // links resolved without cookies may be worse
  }

  List<String> get _base => [
        '--no-warnings',
        '--no-update',
        if (_cookies != null) ...['--cookies', _cookies!],
      ];

  Future<Map<String, dynamic>> _json(List<String> args, {bool js = false}) async {
    final out = await backend.run([..._base, '-J', ...args], js: js);
    try {
      return (jsonDecode(out) as Map).cast<String, dynamic>();
    } on FormatException {
      throw YtException('yt-dlp returned unreadable output');
    }
  }

  T? _hit<T>(Map<String, _Cached<T>> cache, String key) {
    final c = cache[key];
    return (c != null && c.expires.isAfter(_now())) ? c.value : null;
  }

  @override
  Future<List<Track>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final key = q.toLowerCase();
    final cached = _hit(_search, key);
    if (cached != null) return cached;
    final json = await _json(['--flat-playlist', 'ytsearch20:$q']);
    final out = parseSearch(json);
    _search[key] = _Cached(out, _now().add(_searchTtl));
    return out;
  }

  @override
  Future<List<PlaylistResult>> searchPlaylists(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final key = q.toLowerCase();
    final cached = _hit(_plSearch, key);
    if (cached != null) return cached;
    final url =
        'https://www.youtube.com/results?search_query=${Uri.encodeQueryComponent(q)}&sp=$_playlistFilter';
    final json = await _json(['--flat-playlist', '--playlist-end', '20', url]);
    final out = parsePlaylistSearch(json);
    _plSearch[key] = _Cached(out, _now().add(_searchTtl));
    return out;
  }

  @override
  Future<PlaylistContents> playlist(String listId) async {
    if (!isListId(listId)) throw YtException('bad playlist id');
    final cached = _hit(_playlists, listId);
    if (cached != null) return cached;
    final json = await _json(
        ['--flat-playlist', 'https://www.youtube.com/playlist?list=$listId']);
    final out = parsePlaylist(json);
    _playlists[listId] = _Cached(out, _now().add(_listTtl));
    return out;
  }

  @override
  Future<ResolvedStream> resolve(String videoId, {bool fresh = false}) {
    if (!isVideoId(videoId)) throw YtException('bad video id');
    final hit = _streams[videoId];
    if (!fresh && hit != null && hit.expiresAt.isAfter(_now())) {
      return Future.value(hit);
    }
    // One lookup at a time per video: the player and the "warm next" call often overlap.
    return _inflight[videoId] ??= () async {
      try {
        final s = await _lookup(videoId);
        _streams[videoId] = s;
        return s;
      } finally {
        _inflight.remove(videoId);
      }
    }();
  }

  List<String> _resolveArgs(String videoId) => [
        '-f', _audioFormat, '--no-playlist',
        'https://www.youtube.com/watch?v=$videoId',
      ];

  /// Two steps. First without a JS runtime (about 2 s: yt-dlp falls back to a YouTube client whose links
  /// need no challenge), and the link is checked with a 2-byte Range request. If that fails for any reason,
  /// again with the JS runtime (about 10 s, but solves YouTube's challenges).
  Future<ResolvedStream> _lookup(String videoId) async {
    try {
      final fast = parseResolve(await _json(_resolveArgs(videoId)), now: _now());
      if (await _probe(fast)) return fast;
    } on UnplayableException {
      rethrow; // a live stream is a live stream with or without JS
    } catch (_) {
      // fall through to the slow path
    }
    return parseResolve(await _json(_resolveArgs(videoId), js: true), now: _now());
  }

  @override
  Future<String> download(String videoId, String outDir) async {
    if (!isVideoId(videoId)) throw YtException('bad video id');
    final template = '$outDir${Platform.pathSeparator}$videoId.%(ext)s';
    Future<String> go(bool js) => backend.run([
          ..._base,
          '-f', _audioFormat, '--no-playlist', '--no-part', '--no-mtime',
          '-o', template, '--print', 'after_move:filepath',
          'https://www.youtube.com/watch?v=$videoId',
        ], timeout: const Duration(minutes: 10), js: js);
    String out;
    try {
      out = await go(false);
    } on YtException {
      out = await go(true);
    }
    final path = out.trim().split('\n').where((l) => l.isNotEmpty).lastOrNull;
    if (path == null) throw YtException('download produced no file');
    return path;
  }

  @override
  Future<String> update() async {
    final v = await backend.update();
    _streams.clear();
    return v;
  }

  @override
  Future<String> version() => backend.version();
}
