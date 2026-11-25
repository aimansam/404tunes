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

  final app = AppState(
    profiles: ProfilesRepo(db),
    playlists: PlaylistsRepo(db),
    player: player,
    settings: settings,
    yt: yt,
    presence: presence,
  );

  if (systemMediaControlsSupported) await initAudioService(player);

  runApp(TunesApp(app: app, cache: cache));
  await app.start();

  // Get yt-dlp ready in the background so the first search is fast.
  backend.init().catchError((_) {});
}
