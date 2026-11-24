import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import 'player_controller.dart';

/// Connects the player to the system: notification, lock screen, headset buttons, Bluetooth controls.
/// Only used on platforms audio_service supports (Android, iOS, macOS).
bool get systemMediaControlsSupported =>
    Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

Future<TunesAudioHandler> initAudioService(PlayerController c) => AudioService.init(
      builder: () => TunesAudioHandler(c),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'dev.tunes404.playback',
        androidNotificationChannelName: '404tunes playback',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      ),
    );

class TunesAudioHandler extends BaseAudioHandler with SeekHandler {
  TunesAudioHandler(this.c) {
    c.player.playbackEventStream.listen((_) => _publish());
    c.addListener(_onController);
    _onController();
  }

  final PlayerController c;
  String? _lastId;

  void _onController() {
    final t = c.current;
    if (t == null) {
      if (_lastId != null) {
        _lastId = null;
        mediaItem.add(null);
      }
    } else if (t.id != _lastId) {
      _lastId = t.id;
      mediaItem.add(MediaItem(
        id: t.id,
        title: t.title,
        artist: t.channel,
        duration: t.duration == null ? null : Duration(seconds: t.duration!),
        artUri: Uri.parse(t.thumbUrl),
      ));
    }
    _publish();
  }

  void _publish() {
    final p = c.player;
    final processing = c.loading
        ? AudioProcessingState.loading
        : const {
            ProcessingState.idle: AudioProcessingState.idle,
            ProcessingState.loading: AudioProcessingState.loading,
            ProcessingState.buffering: AudioProcessingState.buffering,
            ProcessingState.ready: AudioProcessingState.ready,
            ProcessingState.completed: AudioProcessingState.completed,
          }[p.processingState]!;
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (p.playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: processing,
      playing: p.playing,
      updatePosition: p.position,
      bufferedPosition: p.bufferedPosition,
      speed: p.speed,
    ));
  }

  @override
  Future<void> play() => c.resume();

  @override
  Future<void> pause() => c.pause();

  @override
  Future<void> skipToNext() => c.next();

  @override
  Future<void> skipToPrevious() => c.previous();

  @override
  Future<void> seek(Duration position) => c.seek(position);

  @override
  Future<void> stop() async {
    await c.pause();
    await super.stop();
  }
}
