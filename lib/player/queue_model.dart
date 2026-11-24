import 'dart:math';

import '../yt/models.dart';

enum Repeat { off, all, one }

/// A track in the queue. [uid] makes duplicates (the same song added twice) distinguishable.
class QueueItem {
  const QueueItem(this.uid, this.track);
  final int uid;
  final Track track;
}

/// The play queue: one list plus a current position. No audio, no IO, so it is easy to test.
///
/// Shuffle keeps the already-played part and the current song in place and shuffles what comes after;
/// switching it off restores the order the songs were queued in.
class QueueModel {
  QueueModel({Random? random}) : _random = random ?? Random();

  final Random _random;
  var _nextUid = 1;
  List<QueueItem> _items = [];
  List<QueueItem>? _natural; // order before shuffling, while shuffle is on
  int _pos = -1;

  bool get shuffle => _natural != null;
  Repeat repeat = Repeat.off;

  List<QueueItem> get items => List.unmodifiable(_items);
  int get position => _pos;
  bool get isEmpty => _items.isEmpty;
  QueueItem? get current =>
      _pos >= 0 && _pos < _items.length ? _items[_pos] : null;

  /// The song that will start after the current one ends (null at the end with repeat off).
  QueueItem? get upNext {
    final i = _nextIndex();
    return i == null ? null : _items[i];
  }

  QueueItem _wrap(Track t) => QueueItem(_nextUid++, t);

  /// Replace the whole queue. [shuffled] starts it already shuffled (the song at [start] still plays first).
  void setQueue(List<Track> tracks, {int start = 0, bool? shuffled}) {
    _items = tracks.map(_wrap).toList();
    _natural = null;
    _pos = _items.isEmpty ? -1 : start.clamp(0, _items.length - 1);
    if (shuffled ?? shuffle) _shuffleRest();
  }

  void add(Track t) {
    final item = _wrap(t);
    _items.add(item);
    _natural?.add(item);
    if (_pos < 0) _pos = 0;
  }

  void addAll(Iterable<Track> tracks) => tracks.forEach(add);

  /// Insert right after the current song.
  void playNext(Track t) {
    final item = _wrap(t);
    _items.insert(_pos + 1, item);
    _natural?.add(item);
    if (_pos < 0) _pos = 0;
  }

  /// Removes the song at [index]. Returns true if it was the current one (the caller should load the new current).
  bool removeAt(int index) {
    if (index < 0 || index >= _items.length) return false;
    final removed = _items.removeAt(index);
    _natural?.removeWhere((e) => e.uid == removed.uid);
    final wasCurrent = index == _pos;
    if (index < _pos) _pos--;
    if (_items.isEmpty) {
      _pos = -1;
    } else if (_pos >= _items.length) {
      _pos = repeat == Repeat.all ? 0 : _items.length - 1;
    }
    return wasCurrent;
  }

  void move(int from, int to) {
    if (from < 0 || from >= _items.length) return;
    to = to.clamp(0, _items.length - 1);
    final cur = current;
    final item = _items.removeAt(from);
    _items.insert(to, item);
    if (cur != null) _pos = _items.indexWhere((e) => e.uid == cur.uid);
  }

  void clear() {
    _items = [];
    _natural = null;
    _pos = -1;
  }

  /// Keep only the current song.
  void clearUpcoming() {
    final cur = current;
    if (cur == null) return;
    _items = [cur];
    _natural = _natural == null ? null : [cur];
    _pos = 0;
  }

  void jumpTo(int index) {
    if (index >= 0 && index < _items.length) _pos = index;
  }

  int? _nextIndex() {
    if (_items.isEmpty) return null;
    if (_pos + 1 < _items.length) return _pos + 1;
    return repeat == Repeat.all ? 0 : null;
  }

  /// Moves to the next song. Returns false when there is none (end of queue, repeat off).
  bool next() {
    final i = _nextIndex();
    if (i == null) return false;
    if (i == 0 && shuffle && _items.length > 1) _reshuffleAll();
    _pos = i;
    return true;
  }

  /// Moves to the previous song. At the start it stays put (the caller restarts the song).
  bool previous() {
    if (_pos > 0) {
      _pos--;
      return true;
    }
    if (repeat == Repeat.all && _items.isNotEmpty) {
      _pos = _items.length - 1;
      return true;
    }
    return false;
  }

  void setShuffle(bool on) {
    if (on == shuffle) return;
    if (on) {
      _shuffleRest();
    } else {
      final cur = current;
      final natural = _natural!;
      _natural = null;
      // keep anything that is still queued, in its original order
      final alive = _items.map((e) => e.uid).toSet();
      _items = natural.where((e) => alive.contains(e.uid)).toList();
      _pos = cur == null ? -1 : _items.indexWhere((e) => e.uid == cur.uid);
    }
  }

  void _shuffleRest() {
    if (_items.isEmpty) return;
    _natural = List.of(_items);
    final head = _items.sublist(0, _pos + 1);
    final tail = _items.sublist(_pos + 1)..shuffle(_random);
    _items = [...head, ...tail];
  }

  /// New round with repeat-all: shuffle everything, keeping the next song from being the one that just played.
  void _reshuffleAll() {
    final last = current;
    _items = List.of(_items)..shuffle(_random);
    if (last != null && _items.length > 1 && _items.first.uid == last.uid) {
      final swap = 1 + _random.nextInt(_items.length - 1);
      final t = _items[0];
      _items[0] = _items[swap];
      _items[swap] = t;
    }
  }

  // ---- saving ----

  Map<String, Object?> toJson() => {
        'pos': _pos,
        'shuffle': shuffle,
        'repeat': repeat.name,
        'tracks': _items.map((e) => e.track.toMap()).toList(),
      };

  /// Restores a saved queue. A saved shuffled order is kept as is (the original order is not saved).
  void restore(Map<String, dynamic> json) {
    final raw = json['tracks'];
    final tracks = <Track>[];
    if (raw is List) {
      for (final m in raw) {
        try {
          if (m is Map) tracks.add(Track.fromMap(m.cast<String, Object?>()));
        } catch (_) {
          // skip an unreadable entry
        }
      }
    }
    _items = tracks.map(_wrap).toList();
    _natural = (json['shuffle'] == true) ? List.of(_items) : null;
    final p = json['pos'];
    final pos = p is num ? p.toInt() : 0;
    _pos = _items.isEmpty ? -1 : pos.clamp(0, _items.length - 1);
    repeat = Repeat.values.firstWhere((r) => r.name == json['repeat'],
        orElse: () => Repeat.off);
  }
}
