import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Opens the app database. Desktop uses the FFI SQLite; Android uses the platform one.
Future<Database> openAppDb({String? path}) async {
  if (path == null) {
    if (Platform.isAndroid) {
      path = p.join(await getDatabasesPath(), '404tunes.db');
    } else {
      path = p.join((await getApplicationSupportDirectory()).path, '404tunes.db');
    }
  }
  if (!Platform.isAndroid && !Platform.isIOS) {
    sqfliteFfiInit();
    return databaseFactoryFfi.openDatabase(path, options: _options);
  }
  return openDatabase(path,
      version: _options.version,
      onConfigure: _options.onConfigure,
      onCreate: _options.onCreate);
}

/// In-memory database for tests.
Future<Database> openMemoryDb() {
  sqfliteFfiInit();
  return databaseFactoryFfi.openDatabase(inMemoryDatabasePath, options: _options);
}

final _options = OpenDatabaseOptions(
  version: 1,
  onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
  onCreate: (db, _) async {
    await db.execute('''
      CREATE TABLE profiles (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE COLLATE NOCASE,
        salt BLOB NOT NULL,
        hash BLOB NOT NULL,
        iterations INTEGER NOT NULL,
        is_admin INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )''');
    await db.execute('''
      CREATE TABLE playlists (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        profile_id INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )''');
    await db.execute('''
      CREATE TABLE playlist_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
        position INTEGER NOT NULL,
        video_id TEXT NOT NULL,
        title TEXT NOT NULL,
        channel TEXT NOT NULL DEFAULT '',
        duration INTEGER
      )''');
    await db.execute(
        'CREATE INDEX playlist_items_pos ON playlist_items(playlist_id, position)');
    await db.execute('''
      CREATE TABLE profile_kv (
        profile_id INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
        key TEXT NOT NULL,
        value TEXT NOT NULL,
        PRIMARY KEY (profile_id, key)
      )''');
  },
);
