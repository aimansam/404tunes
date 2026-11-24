import 'package:sqflite/sqflite.dart';

/// Small per-profile key/value store (saved queue, volume, shuffle/repeat, ...).
class KvRepo {
  KvRepo(this.db);
  final Database db;

  Future<String?> get(int profileId, String key) async {
    final r = await db.query('profile_kv',
        columns: ['value'],
        where: 'profile_id = ? AND key = ?',
        whereArgs: [profileId, key]);
    return r.isEmpty ? null : r.first['value'] as String;
  }

  Future<void> set(int profileId, String key, String value) => db.insert(
      'profile_kv', {'profile_id': profileId, 'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace);
}
