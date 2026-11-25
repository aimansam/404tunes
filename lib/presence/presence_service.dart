import 'dart:async';

import 'package:flutter/foundation.dart';

import '../yt/models.dart';
import 'discord_rpc.dart';

/// What the player is doing right now, as far as Discord cares.
class NowPlaying {
  const NowPlaying(this.track, {required this.playing, required this.position});
  final Track track;
  final bool playing;
  final Duration position;
}

enum PresenceStatus {
  /// Turned off, or no application ID.
  off,

  /// On, but nothing is playing.
  idle,

  /// Showing the current song on Discord.
  showing,

  /// On, but the Discord desktop app can't be reached (not running, or it refused).
  unavailable,
}

String _clip(String s) {
  // Discord wants 2 to 128 characters for these fields.
  var t = s.trim();
  if (t.length > 128) t = '${t.substring(0, 127)}…';
  return t.length < 2 ? '$t​' : t;
}

/// The "Listening to" activity for [np]. Timestamps give Discord a progress bar.
Map<String, Object?> buildActivity(NowPlaying np, {DateTime? now}) {
  final t = np.track;
  final startMs = (now ?? DateTime.now()).millisecondsSinceEpoch - np.position.inMilliseconds;
  final artist = t.channel.replaceFirst(RegExp(r'\s*-\s*Topic$'), '').trim(); // YouTube's auto "Artist - Topic" channels
  return {
    'type': 2, // Listening
    'details': _clip(t.title),
    if (artist.isNotEmpty) 'state': _clip(artist),
    'timestamps': {
      'start': startMs ~/ 1000,
      if (t.duration != null && t.duration! > 0) 'end': startMs ~/ 1000 + t.duration!,
    },
    'assets': {'large_image': t.thumbUrl, 'large_text': _clip(t.title)},
  };
}

/// Keeps Discord in step with the player: shows the song while it plays, clears it on pause or stop,
/// and does not hammer Discord (it limits how often a status may change).
class PresenceService {
  PresenceService({
    required this.sink,
    required this.read,
    required this.enabled,
    this.debounce = const Duration(milliseconds: 800),
    this.retryAfter = const Duration(seconds: 30),
    this.seekCheck = const Duration(seconds: 5),
    this.seekTolerance = const Duration(seconds: 4),
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final ActivitySink sink;
  final NowPlaying? Function() read;
  final bool Function() enabled;
  final Duration debounce, retryAfter, seekCheck, seekTolerance;
  final DateTime Function() _now;

  final status = ValueNotifier<PresenceStatus>(PresenceStatus.off);

  Timer? _debounce, _poll, _retry;
  bool _shown = false;
  bool _busy = false, _again = false;
  String? _shownId;
  DateTime? _shownStart;
  DateTime? _blockedUntil;

  /// Call whenever the player or the settings change.
  void poke() {
    _debounce?.cancel();
    _debounce = Timer(debounce, _sync);
  }

  Future<void> _sync() async {
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    try {
      do {
        _again = false;
        await _syncOnce();
      } while (_again);
    } finally {
      _busy = false;
    }
  }

  Future<void> _syncOnce() async {
    if (!enabled()) {
      _stopTimers();
      await _hide(disconnect: true);
      _set(PresenceStatus.off);
      return;
    }
    final np = read();
    if (np == null || !np.playing) {
      _stopTimers();
      await _hide();
      _set(PresenceStatus.idle);
      return;
    }

    final now = _now();
    final start = now.subtract(np.position);
    final sameSong = _shown && _shownId == np.track.id;
    if (sameSong && _shownStart != null && start.difference(_shownStart!).abs() < seekTolerance) {
      return; // nothing changed worth telling Discord
    }
    if (_blockedUntil != null && now.isBefore(_blockedUntil!)) return;

    final ok = await sink.setActivity(buildActivity(np, now: now));
    if (ok) {
      _shown = true;
      _shownId = np.track.id;
      _shownStart = start;
      _blockedUntil = null;
      _set(PresenceStatus.showing);
      // A seek or a stall moves the start time: check now and then.
      _poll ??= Timer.periodic(seekCheck, (_) => poke());
    } else {
      _shown = false;
      _blockedUntil = now.add(retryAfter);
      _set(PresenceStatus.unavailable);
      _retry?.cancel();
      _retry = Timer(retryAfter, poke); // try again later, in case Discord was started meanwhile
    }
  }

  Future<void> _hide({bool disconnect = false}) async {
    if (_shown) {
      _shown = false;
      _shownId = null;
      _shownStart = null;
      await sink.clearActivity();
    }
    if (disconnect) await sink.disconnect();
  }

  void _stopTimers() {
    _poll?.cancel();
    _poll = null;
    _retry?.cancel();
    _retry = null;
    _blockedUntil = null;
  }

  void _set(PresenceStatus s) {
    if (status.value != s) status.value = s;
  }

  Future<void> dispose() async {
    _debounce?.cancel();
    _stopTimers();
    await sink.disconnect();
  }
}
