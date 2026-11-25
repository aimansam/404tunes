import 'models.dart';

/// Pure functions that turn yt-dlp `-J` output into app models.

final _videoId = RegExp(r'^[\w-]{11}$');
final _listId = RegExp(r'^[\w-]{10,64}$');
const _notPlayableTitles = {'[Private video]', '[Deleted video]'};

bool isVideoId(String s) => _videoId.hasMatch(s);
bool isListId(String s) => _listId.hasMatch(s);

List<Map<String, dynamic>> _entries(Map<String, dynamic> json) =>
    ((json['entries'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();

String _channelOf(Map<String, dynamic> e) =>
    (e['channel'] ?? e['uploader'] ?? '') as String;

/// `ytsearch20:<q>` with --flat-playlist. Drops live / upcoming / duration-less entries.
List<Track> parseSearch(Map<String, dynamic> json) {
  final out = <Track>[];
  for (final e in _entries(json)) {
    final id = e['id'];
    if (id is! String || !isVideoId(id)) continue;
    final live = e['live_status'];
    if (live == 'is_live' || live == 'is_upcoming') continue;
    final duration = (e['duration'] as num?)?.toInt();
    if (duration == null || duration == 0) continue;
    out.add(Track(
        id: id,
        title: (e['title'] ?? '') as String,
        channel: _channelOf(e),
        duration: duration));
  }
  return out;
}

/// Video id hidden inside a result's thumbnail URL (playlists show their first video's picture).
String? thumbIdOf(Map<String, dynamic> entry) {
  final thumbs = ((entry['thumbnails'] as List?) ?? const []).reversed;
  final re = RegExp(r'/vi/([\w-]{11})/');
  for (final t in thumbs) {
    final url = (t is Map ? t['url'] : null) as String?;
    final m = url == null ? null : re.firstMatch(url);
    if (m != null) return m.group(1);
  }
  return null;
}

/// YouTube results page with the "type: playlist" filter.
List<PlaylistResult> parsePlaylistSearch(Map<String, dynamic> json) {
  final out = <PlaylistResult>[];
  for (final e in _entries(json)) {
    final id = e['id'];
    final url = (e['url'] ?? '') as String;
    if (id is! String || !isListId(id) || !url.contains('list=')) continue;
    out.add(PlaylistResult(
        listId: id,
        title: (e['title'] ?? '') as String,
        channel: _channelOf(e),
        thumbVideoId: thumbIdOf(e)));
  }
  return out;
}

/// `playlist?list=` with --flat-playlist. Drops private / deleted / live entries.
PlaylistContents parsePlaylist(Map<String, dynamic> json) {
  final items = <Track>[];
  for (final e in _entries(json)) {
    final id = e['id'];
    final title = (e['title'] ?? '') as String;
    if (id is! String || !isVideoId(id)) continue;
    if (_notPlayableTitles.contains(title) || e['live_status'] == 'is_live') {
      continue;
    }
    items.add(Track(
        id: id,
        title: title,
        channel: _channelOf(e),
        duration: (e['duration'] as num?)?.toInt()));
  }
  return PlaylistContents(title: (json['title'] ?? '') as String, items: items);
}

/// `-f bestaudio... -J` output -> a direct audio stream.
/// Refresh time is 10 minutes before the URL's `expire` (3 hours when absent).
ResolvedStream parseResolve(Map<String, dynamic> info, {DateTime? now}) {
  now ??= DateTime.now();
  if (info['is_live'] == true) {
    throw UnplayableException("live streams can't be played");
  }
  final formats = info['requested_formats'];
  final fmt = (formats is List && formats.isNotEmpty
          ? formats.first
          : info)
      .cast<String, dynamic>();
  final protocol = (fmt['protocol'] ?? 'https') as String;
  if (protocol != 'https' && protocol != 'http') {
    throw UnplayableException('unsupported stream type $protocol');
  }
  final url = fmt['url'] as String;
  final expire = int.tryParse(Uri.parse(url).queryParameters['expire'] ?? '');
  final expiresAt = expire != null
      ? DateTime.fromMillisecondsSinceEpoch(expire * 1000)
          .subtract(const Duration(minutes: 10))
      : now.add(const Duration(hours: 3));
  final avail = (fmt['available_at'] ?? info['available_at']) as num?;
  final headers = <String, String>{
    for (final e in ((fmt['http_headers'] as Map?) ?? const {}).entries)
      e.key as String: '${e.value}',
  };
  return ResolvedStream(
    track: Track(
      id: info['id'] as String,
      title: (info['title'] ?? '') as String,
      channel: _channelOf(info),
      duration: (info['duration'] as num?)?.toInt(),
    ),
    url: url,
    headers: headers,
    expiresAt: expiresAt,
    availableAt: avail == null || avail == 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(avail.toInt() * 1000),
  );
}
