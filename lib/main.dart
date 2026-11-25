import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'app_state.dart';
import 'data/db.dart';
import 'data/kv_repo.dart';
import 'data/playlists_repo.dart';
import 'data/profiles_repo.dart';
import 'player/audio_handler.dart';
import 'player/cache_manager.dart';
import 'player/player_controller.dart';
import 'presence/discord_rpc.dart';
import 'presence/presence_service.dart';
import 'settings.dart';
import 'update/installer.dart';
import 'update/installer_android.dart';
import 'update/update_controller.dart';
import 'update/updater.dart';
import 'update/version.dart';
import 'yt/backend.dart';
import 'yt/backend_android.dart';
import 'yt/backend_desktop.dart';
import 'yt/ytdlp_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Desktop plays audio through libmpv (media_kit): it handles the WebM/Opus audio YouTube serves, which the
  // macOS system player cannot. Android uses ExoPlayer.
  if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
    JustAudioMediaKit.ensureInitialized(linux: true, windows: true, macOS: true);
  }

  final YtBackend backend = Platform.isAndroid ? AndroidBackend() : DesktopBackend();
  final yt = YtDlpService(backend);
  final settings = await AppSettings.load();
  final db = await openAppDb();
  final cacheDir = Directory(p.join((await getApplicationCacheDirectory()).path, 'audio'));
  final cache = CacheManager(cacheDir, yt);

  final player = PlayerController(yt: yt, cache: cache, settings: settings, kv: KvRepo(db));
  // Discord Rich Presence: only on desktop, where the Discord app listens on a local socket.
  PresenceService? presence;
  if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
    final rpc = DiscordRpc(clientId: settings.discordClientId);
    presence = PresenceService(
      sink: rpc,
      enabled: () => settings.discordEnabled && settings.discordClientId.isNotEmpty,
      read: () {
        final t = player.current;
        if (t == null) return null;
        return NowPlaying(t, playing: player.playing && !player.loading, position: player.player.position);
      },
    );
    player.addListener(presence.poke);
    settings.addListener(() {
      rpc.clientId = settings.discordClientId;
      presence!.poke();
    });
  }

  // App updates from GitHub releases. Only builds made from a release tag know their version and look for updates.
  final updates = UpdateController(
    updater: Updater(currentVersion: Version.tryParse(const String.fromEnvironment('APP_VERSION'))),
    installer: Platform.isAndroid
        ? AndroidInstaller()
        : DesktopInstaller(
            operatingSystem: Platform.operatingSystem,
            executable: Platform.resolvedExecutable,
            quit: () async {
              await player.pause();
              await player.saveNow();
              exit(0);
            },
          ),
    settings: settings,
    // Android: must be <cache>/updates, the folder MainActivity and update_paths.xml allow.
    downloadDir: () async => Directory(p.join((await getTemporaryDirectory()).path, Platform.isAndroid ? 'updates' : '404tunes-update')),
  );

  final app = AppState(
    profiles: ProfilesRepo(db),
    playlists: PlaylistsRepo(db),
    player: player,
    settings: settings,
    yt: yt,
    presence: presence,
    updates: updates,
  );

  if (systemMediaControlsSupported) await initAudioService(player);

  runApp(TunesApp(app: app, cache: cache));
  await app.start();

  updates.start();

  // Get yt-dlp ready in the background so the first search is fast.
  await backend.init().catchError((_) {});

  // Desktop: keep yt-dlp current (Android does this in YtDlpPlugin). Not right away, so the first search isn't held up.
  if (backend is DesktopBackend) {
    void refresh() => backend.updateIfDue().catchError((_) => false);
    Timer(const Duration(seconds: 30), refresh);
    Timer.periodic(const Duration(hours: 6), (_) => refresh());
  }
}
