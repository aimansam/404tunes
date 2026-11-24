import 'models.dart';

/// The only place in the app that talks to yt-dlp.
///
/// Implementations: `DesktopYt` (bundled yt-dlp binary via Process) and `AndroidYt`
/// (youtubedl-android over a MethodChannel). Tests use a fake.
///
/// Behaviour ported from shinsoku's api/server.py:
///  - search: `ytsearch20:<q>`, drop live / upcoming / no-duration entries
///  - searchPlaylists: results page with the `sp=EgIQAw%3D%3D` filter
///  - playlist: flat extraction, drop private / deleted / live entries
///  - resolve: bestaudio[ext=webm]/bestaudio[ext=m4a]/bestaudio, reject live,
///    cache until ~10 min before `expire`, honour `available_at`
abstract class YtService {
  Future<List<Track>> search(String query);

  Future<List<PlaylistResult>> searchPlaylists(String query);

  Future<PlaylistContents> playlist(String listId);

  /// Direct audio URL + headers. [fresh] bypasses the cache (use after an HTTP 403).
  Future<ResolvedStream> resolve(String videoId, {bool fresh = false});

  /// Download the audio of [videoId] into [outDir]; returns the file path.
  Future<String> download(String videoId, String outDir);

  /// Path to a Netscape cookies.txt, or null. Used when YouTube asks to confirm you're not a bot.
  set cookiesPath(String? path);

  /// Pull the newest yt-dlp (YouTube changes often). Returns the version now in use.
  Future<String> update();

  Future<String> version();
}
