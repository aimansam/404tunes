import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:sqflite/sqflite.dart';

class Profile {
  const Profile({required this.id, required this.name, required this.isAdmin});
  final int id;
  final String name;
  final bool isAdmin;
}

class ProfileException implements Exception {
  ProfileException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Local profiles with a PIN / password. This separates people's playlists and queues on one device;
/// it is a lock, not encryption (the database file itself is not encrypted).
class ProfilesRepo {
  ProfilesRepo(this.db, {this.iterations = 50000});

  final Database db;
  final int iterations;

  static const minSecretLength = 4;

  Profile _from(Map<String, Object?> r) => Profile(
      id: r['id'] as int,
      name: r['name'] as String,
      isAdmin: (r['is_admin'] as int) == 1);

  Future<int> count() async => Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM profiles')) ??
      0;

  Future<bool> needsSetup() async => (await count()) == 0;

  Future<List<Profile>> list() async => (await db.query('profiles',
          orderBy: 'is_admin DESC, name COLLATE NOCASE'))
      .map(_from)
      .toList();

  Future<Profile?> byId(int id) async {
    final r = await db.query('profiles', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : _from(r.first);
  }

  Future<Uint8List> _derive(String secret, List<int> salt, int iters) async {
    final key = await Pbkdf2(
            macAlgorithm: Hmac.sha256(), iterations: iters, bits: 256)
        .deriveKeyFromPassword(password: secret, nonce: salt);
    return Uint8List.fromList(await key.extractBytes());
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  void _checkName(String name) {
    if (name.trim().isEmpty) throw ProfileException('Enter a name');
  }

  void _checkSecret(String secret) {
    if (secret.length < minSecretLength) {
      throw ProfileException('PIN / password must be at least $minSecretLength characters');
    }
  }

  Future<Profile> create(String name, String secret, {bool isAdmin = false}) async {
    name = name.trim();
    _checkName(name);
    _checkSecret(secret);
    final rnd = Random.secure();
    final salt = Uint8List.fromList(List.generate(16, (_) => rnd.nextInt(256)));
    final hash = await _derive(secret, salt, iterations);
    try {
      final id = await db.insert('profiles', {
        'name': name,
        'salt': salt,
        'hash': hash,
        'iterations': iterations,
        'is_admin': isAdmin ? 1 : 0,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
      return Profile(id: id, name: name, isAdmin: isAdmin);
    } on DatabaseException catch (e) {
      if (e.isUniqueConstraintError()) {
        throw ProfileException('A profile named "$name" already exists');
      }
      rethrow;
    }
  }

  /// The very first profile on a fresh install is the admin. Refused once any profile exists.
  Future<Profile> createFirstAdmin(String name, String secret) async {
    if (!await needsSetup()) throw ProfileException('Setup is already done');
    return create(name, secret, isAdmin: true);
  }

  Future<bool> verify(int id, String secret) async {
    final r = await db.query('profiles', where: 'id = ?', whereArgs: [id]);
    if (r.isEmpty) return false;
    final row = r.first;
    final hash = await _derive(
        secret, row['salt'] as List<int>, row['iterations'] as int);
    return _constantTimeEquals(hash, row['hash'] as List<int>);
  }

  Future<void> setSecret(int id, String secret) async {
    _checkSecret(secret);
    final rnd = Random.secure();
    final salt = Uint8List.fromList(List.generate(16, (_) => rnd.nextInt(256)));
    final hash = await _derive(secret, salt, iterations);
    await db.update(
        'profiles', {'salt': salt, 'hash': hash, 'iterations': iterations},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> rename(int id, String name) async {
    name = name.trim();
    _checkName(name);
    try {
      await db.update('profiles', {'name': name}, where: 'id = ?', whereArgs: [id]);
    } on DatabaseException catch (e) {
      if (e.isUniqueConstraintError()) {
        throw ProfileException('A profile named "$name" already exists');
      }
      rethrow;
    }
  }

  /// Admin removes a profile and, through cascades, its playlists and saved queue.
  /// The acting admin cannot delete themselves and the last admin can never be removed.
  Future<void> delete(int id, {required int actingAdminId}) async {
    final actor = await byId(actingAdminId);
    if (actor == null || !actor.isAdmin) {
      throw ProfileException('Only an admin can delete profiles');
    }
    if (id == actingAdminId) {
      throw ProfileException("You can't delete your own profile");
    }
    final target = await byId(id);
    if (target == null) return;
    if (target.isAdmin) {
      final admins = Sqflite.firstIntValue(await db
              .rawQuery('SELECT COUNT(*) FROM profiles WHERE is_admin = 1')) ??
          0;
      if (admins <= 1) throw ProfileException('At least one admin must remain');
    }
    await db.delete('profiles', where: 'id = ?', whereArgs: [id]);
  }
}
