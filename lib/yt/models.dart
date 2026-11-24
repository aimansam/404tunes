// Plain data types shared by the yt-dlp services, the player and the database.

class Track {
  const Track({
    required this.id,
    required this.title,
    this.channel = '',
    this.duration,
  });

  final String id; // YouTube video id (11 chars)
  final String title;
  final String channel;
  final int? duration; // seconds

  String get thumbUrl => 'https://i.ytimg.com/vi/$id/mqdefault.jpg';

  Map<String, Object?> toMap() =>
      {'id': id, 'title': title, 'channel': channel, 'duration': duration};

  factory Track.fromMap(Map<String, Object?> m) => Track(
        id: m['id'] as String,
        title: (m['title'] as String?) ?? '',
        channel: (m['channel'] as String?) ?? '',
        duration: (m['duration'] as num?)?.toInt(),
      );
}

class PlaylistResult {
  const PlaylistResult({
    required this.listId,
    required this.title,
    this.channel = '',
    this.thumbVideoId,
  });

  final String listId;
  final String title;
  final String channel;
  final String? thumbVideoId;
}

class PlaylistContents {
  const PlaylistContents({required this.title, required this.items});
  final String title;
  final List<Track> items;
}

/// A direct audio stream for one video, as resolved by yt-dlp.
class ResolvedStream {
  const ResolvedStream({
    required this.track,
    required this.url,
    required this.headers,
    required this.expiresAt,
    required this.availableAt,
  });

  final Track track;
  final String url;
  final Map<String, String> headers;

  /// Refresh a little before the real expiry (see [YtService] resolve).
  final DateTime expiresAt;

  /// YouTube sometimes hands out links that only start working a few seconds later.
  final DateTime? availableAt;

  bool get isFresh => DateTime.now().isBefore(expiresAt);
}

class UnplayableException implements Exception {
  UnplayableException(this.message);
  final String message;
  @override
  String toString() => 'UnplayableException: $message';
}

class YtException implements Exception {
  YtException(this.message);
  final String message;
  @override
  String toString() => 'YtException: $message';
}
