/// Runs yt-dlp. The desktop build spawns a bundled binary; Android calls youtubedl-android.
/// Everything above this (parsing, caches, retries) is shared and lives in `YtDlpService`.
abstract class YtBackend {
  /// Prepare the runtime (extract binaries, init the Android library). Safe to call more than once.
  Future<void> init();

  /// Run yt-dlp with [args] and return its stdout. Throws `YtException` on failure.
  ///
  /// [js] says whether yt-dlp may use the bundled JavaScript runtime (quickjs). With `js: false` it runs
  /// without one, which is much faster but only some YouTube clients work then; callers verify the result
  /// and retry with `js: true` (slower, but solves YouTube's challenges). The backend adds the right
  /// arguments for either mode.
  Future<String> run(List<String> args,
      {Duration timeout = const Duration(seconds: 120), bool js = true});

  /// Update yt-dlp itself and return the version in use afterwards.
  Future<String> update();

  Future<String> version();
}
