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

  /// YouTube player clients to try when the usual ones are answered with the bot check: name, and whether it needs
  /// the JS runtime. yt-dlp doesn't pick these itself. They mostly offer one combined 360p file with sound, so they
  /// are only a fallback. (`web_embedded` is left out: it offers HLS, which `parseResolve` doesn't take.)
  static const _fallbackClients = [('android', false), ('mweb', true), ('tv_simply', true)];
  static const _fallbackTtl = Duration(minutes: 30);

  String? _cookies;
  _Cached<(String, bool)>? _fallback; // the client that last got past the bot check
  final _search = <String, _Cached<List<Track>>>{};
  final _plSearch = <String, _Cached<List<PlaylistResult>>>{};
  final _playlists = <String, _Cached<PlaylistContents>>{};
  final _streams = <String, ResolvedStream>{};
  final _inflight = <String, Future<ResolvedStream>>{};

  @override
  set cookiesPath(String? path) {
    _cookies = (path != null && path.isNotEmpty) ? path : null;
    _streams.clear(); // links resolved without cookies may be worse
    _fallback = null;
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
    var out = parseSearch(await _json(['--flat-playlist', 'ytsearch20:$q']));
    // YouTube now and then answers a whole search without channel names. Ask once more rather than show blank artists.
    if (out.length >= 4 && out.where((t) => t.channel.isEmpty).length * 2 > out.length) {
      try {
        final again = parseSearch(await _json(['--flat-playlist', 'ytsearch20:$q']));
        if (again.where((t) => t.channel.isEmpty).length < out.where((t) => t.channel.isEmpty).length) out = again;
      } catch (_) {}
    }
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
  /// again with the JS runtime (about 10 s, but solves YouTube's challenges). If YouTube answers with its bot
  /// check, the [_fallbackClients] are tried one by one, and the one that works goes first for a while.
  Future<ResolvedStream> _lookup(String videoId) async {
    final known = _fallback;
    if (known != null) {
      if (known.expires.isAfter(_now())) {
        final s = await _tryClient(videoId, known.value);
        if (s != null) return s;
      }
      _fallback = null;
    }
    try {
      final fast = parseResolve(await _json(_resolveArgs(videoId)), now: _now());
      if (await _probe(fast)) return fast;
    } on UnplayableException {
      rethrow; // a live stream is a live stream with or without JS
    } catch (_) {
      // fall through to the slow path
    }
    try {
      return parseResolve(await _json(_resolveArgs(videoId), js: true), now: _now());
    } on YtException catch (e) {
      if (!e.isBotCheck) rethrow;
      for (final client in _fallbackClients) {
        final s = await _tryClient(videoId, client);
        if (s != null) {
          _fallback = _Cached(client, _now().add(_fallbackTtl));
          return s;
        }
      }
      rethrow;
    }
  }

  /// A verified stream from one player client, or null if that client can't deliver one.
  Future<ResolvedStream?> _tryClient(String videoId, (String, bool) client) async {
    final (name, js) = client;
    try {
      final args = ['--extractor-args', 'youtube:player_client=$name', ..._resolveArgs(videoId)];
      final s = parseResolve(await _json(args, js: js), now: _now());
      return await _probe(s) ? s : null;
    } catch (_) {
      return null;
    }
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
    _fallback = null;
    return v;
  }

  @override
  Future<String> version() => backend.version();
}
