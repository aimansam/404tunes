import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../yt/models.dart';

class PlaylistInfo {
  const PlaylistInfo({required this.id, required this.name, required this.count});
  final int id;
  final String name;
  final int count;
}

class PlaylistItem {
  const PlaylistItem({required this.itemId, required this.track});
  final int itemId;
  final Track track;
}

/// Per-profile playlists. Every call takes the profile id and refuses playlists owned by someone else.
class PlaylistsRepo {
  PlaylistsRepo(this.db);
  final Database db;

  /// Goes up after every change, so screens showing playlists know to reload.
  final ValueNotifier<int> revision = ValueNotifier(0);
  void _changed() => revision.value++;

  Future<bool> _owns(DatabaseExecutor ex, int profileId, int playlistId) async =>
      (await ex.query('playlists',
              columns: ['id'],
              where: 'id = ? AND profile_id = ?',
              whereArgs: [playlistId, profileId]))
          .isNotEmpty;

  Future<void> _requireOwner(DatabaseExecutor ex, int profileId, int playlistId) async {
    if (!await _owns(ex, profileId, playlistId)) {
      throw StateError('playlist not found');
    }
  }

  Future<List<PlaylistInfo>> list(int profileId) async {
    final rows = await db.rawQuery('''
      SELECT p.id, p.name, COUNT(i.id) AS n
      FROM playlists p LEFT JOIN playlist_items i ON i.playlist_id = p.id
      WHERE p.profile_id = ?
      GROUP BY p.id ORDER BY p.created_at, p.id''', [profileId]);
    return rows
        .map((r) => PlaylistInfo(
            id: r['id'] as int, name: r['name'] as String, count: r['n'] as int))
        .toList();
  }

  Future<int> create(int profileId, String name) async {
    name = name.trim();
    if (name.isEmpty) throw ArgumentError('Enter a name');
    final id = await db.insert('playlists', {
      'profile_id': profileId,
      'name': name,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
    _changed();
    return id;
  }

  Future<void> rename(int profileId, int playlistId, String name) async {
    name = name.trim();
    if (name.isEmpty) throw ArgumentError('Enter a name');
    await _requireOwner(db, profileId, playlistId);
    await db.update('playlists', {'name': name},
        where: 'id = ?', whereArgs: [playlistId]);
    _changed();
  }

  Future<void> delete(int profileId, int playlistId) async {
    await db.delete('playlists',
        where: 'id = ? AND profile_id = ?', whereArgs: [playlistId, profileId]);
    _changed();
  }

  Future<List<PlaylistItem>> items(int profileId, int playlistId) async {
    await _requireOwner(db, profileId, playlistId);
    final rows = await db.query('playlist_items',
        where: 'playlist_id = ?', whereArgs: [playlistId], orderBy: 'position, id');
    return rows
        .map((r) => PlaylistItem(
            itemId: r['id'] as int,
            track: Track(
                id: r['video_id'] as String,
                title: r['title'] as String,
                channel: (r['channel'] as String?) ?? '',
                duration: r['duration'] as int?)))
        .toList();
  }

  /// Appends tracks to the end. Returns how many were added.
  Future<int> addTracks(int profileId, int playlistId, List<Track> tracks) async {
    final added = await db.transaction((txn) async {
      await _requireOwner(txn, profileId, playlistId);
      var pos = (Sqflite.firstIntValue(await txn.rawQuery(
                  'SELECT MAX(position) FROM playlist_items WHERE playlist_id = ?',
                  [playlistId])) ??
              -1) +
          1;
      for (final t in tracks) {
        await txn.insert('playlist_items', {
          'playlist_id': playlistId,
          'position': pos++,
          'video_id': t.id,
          'title': t.title,
          'channel': t.channel,
          'duration': t.duration,
        });
      }
      return tracks.length;
    });
    _changed();
    return added;
  }

  Future<void> removeItem(int profileId, int playlistId, int itemId) async {
    await _requireOwner(db, profileId, playlistId);
    await db.delete('playlist_items',
        where: 'id = ? AND playlist_id = ?', whereArgs: [itemId, playlistId]);
    _changed();
  }

  /// [orderedItemIds] is the new order of all items in the playlist.
  Future<void> reorder(int profileId, int playlistId, List<int> orderedItemIds) async {
    await db.transaction((txn) async {
      await _requireOwner(txn, profileId, playlistId);
      for (var i = 0; i < orderedItemIds.length; i++) {
        await txn.update('playlist_items', {'position': i},
            where: 'id = ? AND playlist_id = ?',
            whereArgs: [orderedItemIds[i], playlistId]);
      }
    });
    _changed();
  }
}
