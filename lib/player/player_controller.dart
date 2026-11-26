import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../data/kv_repo.dart';
import '../settings.dart';
import '../yt/models.dart';
import '../yt/yt_service.dart';
import 'cache_manager.dart';
import 'queue_model.dart';

/// Plays the queue: resolves each song with yt-dlp (or finds it in the cache), feeds it to just_audio,
/// gets the next song ready ahead of time, and saves the queue per profile.
class PlayerController extends ChangeNotifier {
  PlayerController({
    required this.yt,
    required this.cache,
    required this.settings,
    required this.kv,
    AudioPlayer? player,
  }) : player = player ?? AudioPlayer() {
    _subs.add(this.player.processingStateStream.listen((s) {
      if (s == ProcessingState.completed) _onCompleted();
    }));
    _subs.add(this.player.playbackEventStream.listen((_) {}, onError: _onPlayerError));
    _subs.add(this.player.playingStream.listen((_) => notifyListeners()));
  }

  final YtService yt;
  final CacheManager cache;
  final AppSettings settings;
  final KvRepo kv;
  final AudioPlayer player;
  final QueueModel queue = QueueModel();

  final _subs = <StreamSubscription<Object?>>[];
  int? _profileId;
  int _gen = 0; // bumps on every (re)load so late results from older loads are ignored
  bool _prepared = false; // is the current song loaded into the player?
  bool _recovered = false; // already retried this song after a playback error
  int _failures = 0;
  Timer? _saveTimer;

  bool loading = false;
  String? error;
  double volume = 1.0;

  Track? get current => queue.current?.track;
  bool get playing => player.playing;

  void _changed() {
    notifyListeners();
    _scheduleSave();
  }

  // ---------------------------------------------------------------- profile / saving

  Future<void> attachProfile(int? profileId) async {
    await _flushSave();
    _gen++;
    await player.stop();
    _prepared = false;
    queue.clear();
    error = null;
    loading = false;
    _profileId = profileId;
    if (profileId != null) {
      final raw = await kv.get(profileId, 'queue');
      if (raw != null) {
        try {
          queue.restore((jsonDecode(raw) as Map).cast<String, dynamic>());
        } catch (_) {
          queue.clear();
        }
      }
      final v = await kv.get(profileId, 'volume');
      volume = double.tryParse(v ?? '') ?? 1.0;
      await player.setVolume(volume);
    }
    notifyListeners();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), _flushSave);
  }

  /// Writes the queue out now (the app is about to close).
  Future<void> saveNow() => _flushSave();

  Future<void> _flushSave() async {
    _saveTimer?.cancel();
    final id = _profileId;
    if (id == null) return;
    await kv.set(id, 'queue', jsonEncode(queue.toJson()));
    await kv.set(id, 'volume', volume.toString());
  }

  // ---------------------------------------------------------------- starting songs

  Future<void> playTracks(List<Track> tracks, {int start = 0}) async {
    if (tracks.isEmpty) return;
    queue.setQueue(tracks, start: start);
    _changed();
    await _loadCurrent();
  }

  Future<void> addToQueue(Track t) async {
    final wasEmpty = queue.isEmpty;
    queue.add(t);
    _changed();
    if (wasEmpty) await _loadCurrent(autoplay: false);
  }

  Future<void> addAllToQueue(List<Track> tracks) async {
    final wasEmpty = queue.isEmpty;
    queue.addAll(tracks);
    _changed();
    if (wasEmpty) await _loadCurrent(autoplay: false);
  }

  void playNext(Track t) {
    queue.playNext(t);
    _changed();
  }

  Future<void> jumpTo(int index) async {
    queue.jumpTo(index);
    _changed();
    await _loadCurrent();
  }

  Future<void> removeAt(int index) async {
    final wasCurrent = queue.removeAt(index);
    _changed();
    if (wasCurrent) {
      if (queue.isEmpty) {
        _gen++;
        _prepared = false;
        await player.stop();
      } else {
        await _loadCurrent(autoplay: player.playing);
      }
    }
  }

  void move(int from, int to) {
    queue.move(from, to);
    _changed();
  }

  Future<void> clearQueue() async {
    _gen++;
    queue.clear();
    _prepared = false;
    await player.stop();
    _changed();
  }

  void clearUpcoming() {
    queue.clearUpcoming();
    _changed();
  }

  // ---------------------------------------------------------------- transport

  Future<void> togglePlay() async {
    if (player.playing) {
      await player.pause();
      return;
    }
    await resume();
  }

  Future<void> resume() async {
    if (queue.current == null) return;
    if (!_prepared) {
      await _loadCurrent();
    } else {
      unawaited(player.play());
    }
  }

  Future<void> pause() => player.pause();

  Future<void> next() async {
    if (!queue.next()) {
      await player.pause();
      await player.seek(Duration.zero);
      return;
    }
    _changed();
    await _loadCurrent();
  }

  Future<void> previous() async {
    if (player.position > const Duration(seconds: 3) || !queue.previous()) {
      await player.seek(Duration.zero);
      return;
    }
    _changed();
    await _loadCurrent();
  }

  Future<void> seek(Duration to) => player.seek(to);

  Future<void> setVolume(double v) async {
    volume = v.clamp(0.0, 1.0);
    await player.setVolume(volume);
    _changed();
  }

  void setShuffle(bool on) {
    queue.setShuffle(on);
    _changed();
  }

  void cycleRepeat() {
    queue.repeat = Repeat
        .values[(queue.repeat.index + 1) % Repeat.values.length];
    _changed();
  }

  // ---------------------------------------------------------------- loading

  Future<AudioSource> _sourceFor(Track track, {bool fresh = false}) async {
    final file = await cache.lookup(track.id);
    if (file != null) return AudioSource.file(file.path);
    final s = await yt.resolve(track.id, fresh: fresh);
    final wait = s.availableAt?.difference(DateTime.now());
    if (wait != null && wait > Duration.zero) {
      await Future<void>.delayed(wait > const Duration(seconds: 15)
          ? const Duration(seconds: 15)
          : wait);
    }
    return AudioSource.uri(Uri.parse(s.url), headers: s.headers);
  }

  Future<void> _loadCurrent({bool autoplay = true, bool fresh = false, Duration? resumeAt}) async {
    final item = queue.current;
    final gen = ++_gen;
    if (item == null) {
      _prepared = false;
      await player.stop();
      notifyListeners();
      return;
    }
    loading = true;
    error = null;
    _prepared = false;
    _recovered = fresh;
    notifyListeners();
    try {
      final source = await _sourceFor(item.track, fresh: fresh);
      if (gen != _gen) return;
      await player.setAudioSource(source, initialPosition: resumeAt);
      if (gen != _gen) return;
      _prepared = true;
      _failures = 0;
      loading = false;
      if (autoplay) unawaited(player.play());
      notifyListeners();
      _afterStart(item.track);
    } catch (e) {
      if (gen != _gen) return;
      if (!fresh && !(e is YtException && e.isBotCheck)) {
        // The link may have gone stale: look the song up again once. (After a bot check every option was
        // already tried, and asking again right away only makes YouTube more suspicious.)
        return _loadCurrent(autoplay: autoplay, fresh: true, resumeAt: resumeAt);
      }
      loading = false;
      error = _describe(e);
      notifyListeners();
      // Skip a broken song, but not forever when everything fails (e.g. offline).
      if (autoplay && ++_failures < 3 && queue.upNext != null) {
        Timer(const Duration(seconds: 1), () {
          if (gen == _gen) next();
        });
      }
    }
  }

  void _afterStart(Track track) {
    // Get the next song ready so it starts instantly.
    final up = queue.upNext;
    if (up != null) {
      cache.lookup(up.track.id).then((f) {
        if (f == null) yt.resolve(up.track.id).then((_) {}, onError: (_) {});
      });
    }
    if (settings.cacheEnabled) {
      unawaited(cache.store(track.id, maxBytes: settings.cacheMaxBytes));
    }
  }

  Future<void> _onPlayerError(Object e, StackTrace st) async {
    // Typically HTTP 403 after YouTube's link expired: reload once at the same spot.
    if (_recovered || queue.current == null) return;
    _recovered = true;
    await _loadCurrent(fresh: true, resumeAt: player.position, autoplay: true);
  }

  Future<void> _onCompleted() async {
    if (queue.repeat == Repeat.one) {
      await player.seek(Duration.zero);
      unawaited(player.play());
      return;
    }
    await next();
  }

  static String _describe(Object e) {
    final s = e is UnplayableException
        ? e.message
        : e is YtException
            ? e.message
            : '$e';
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _saveTimer?.cancel();
    player.dispose();
    super.dispose();
  }
}
