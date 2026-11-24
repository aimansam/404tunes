import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tunes404/data/db.dart';
import 'package:tunes404/data/kv_repo.dart';
import 'package:tunes404/data/playlists_repo.dart';
import 'package:tunes404/data/profiles_repo.dart';
import 'package:tunes404/yt/models.dart';

Track t(String n) => Track(id: n.padRight(11, '_'), title: n, channel: 'ch', duration: 60);

void main() {
  late Database db;
  late ProfilesRepo profiles;
  late PlaylistsRepo playlists;

  setUp(() async {
    db = await openMemoryDb();
    // Few iterations: the test is about the rules, not the hashing cost.
    profiles = ProfilesRepo(db, iterations: 1000);
    playlists = PlaylistsRepo(db);
  });
  tearDown(() => db.close());

  group('profiles and admin', () {
    test('fresh database needs setup; the first admin can be created once', () async {
      expect(await profiles.needsSetup(), isTrue);
      final admin = await profiles.createFirstAdmin('Boss', '1234');
      expect(admin.isAdmin, isTrue);
      expect(await profiles.needsSetup(), isFalse);
      expect(() => profiles.createFirstAdmin('Evil', '9999'), throwsA(isA<ProfileException>()));
      expect(await profiles.count(), 1);
    });

    test('verify accepts the right secret only; secrets are not stored in clear', () async {
      final p = await profiles.create('Ann', 'hunter2');
      expect(await profiles.verify(p.id, 'hunter2'), isTrue);
      expect(await profiles.verify(p.id, 'hunter3'), isFalse);
      expect(await profiles.verify(p.id, ''), isFalse);
      expect(await profiles.verify(9999, 'hunter2'), isFalse);
      final row = (await db.query('profiles')).single;
      expect(String.fromCharCodes(row['hash'] as List<int>), isNot(contains('hunter2')));
      expect((row['salt'] as List).length, 16);
    });

    test('same secret gets a different salt and hash for each profile', () async {
      final a = await profiles.create('A', 'samepin');
      final b = await profiles.create('B', 'samepin');
      final rows = await db.query('profiles', orderBy: 'id');
      expect(rows[0]['salt'], isNot(rows[1]['salt']));
      expect(rows[0]['hash'], isNot(rows[1]['hash']));
      expect(await profiles.verify(a.id, 'samepin'), isTrue);
      expect(await profiles.verify(b.id, 'samepin'), isTrue);
    });

    test('validation: short secret, empty name, duplicate name (any case)', () async {
      await expectLater(profiles.create('X', '12'), throwsA(isA<ProfileException>()));
      await expectLater(profiles.create('  ', '1234'), throwsA(isA<ProfileException>()));
      await profiles.create('Dup', '1234');
      await expectLater(profiles.create('dup', '1234'), throwsA(isA<ProfileException>()));
    });

    test('reset secret', () async {
      final p = await profiles.create('Ann', 'oldpin');
      await profiles.setSecret(p.id, 'newpin');
      expect(await profiles.verify(p.id, 'oldpin'), isFalse);
      expect(await profiles.verify(p.id, 'newpin'), isTrue);
    });

    test('admin deletes a profile; cascades remove its playlists and saved state', () async {
      final admin = await profiles.createFirstAdmin('Boss', '1234');
      final kid = await profiles.create('Kid', '1234');
      final pl = await playlists.create(kid.id, 'Kid mix');
      await playlists.addTracks(kid.id, pl, [t('a'), t('b')]);
      await KvRepo(db).set(kid.id, 'queue', '{}');
      await profiles.delete(kid.id, actingAdminId: admin.id);
      expect(await profiles.byId(kid.id), isNull);
      expect(await db.query('playlists'), isEmpty);
      expect(await db.query('playlist_items'), isEmpty);
      expect(await db.query('profile_kv'), isEmpty);
    });

    test('admin cannot delete self; non-admin cannot delete anyone; last admin stays', () async {
      final admin = await profiles.createFirstAdmin('Boss', '1234');
      final kid = await profiles.create('Kid', '1234');
      await expectLater(profiles.delete(admin.id, actingAdminId: admin.id), throwsA(isA<ProfileException>()));
      await expectLater(profiles.delete(admin.id, actingAdminId: kid.id), throwsA(isA<ProfileException>()));
      await expectLater(profiles.delete(kid.id, actingAdminId: kid.id), throwsA(isA<ProfileException>()));
      final admin2 = await profiles.create('Boss2', '1234', isAdmin: true);
      await profiles.delete(admin2.id, actingAdminId: admin.id); // allowed: another admin remains
      expect((await profiles.list()).map((p) => p.name), containsAll(['Boss', 'Kid']));
    });

    test('rename keeps names unique', () async {
      final a = await profiles.create('A', '1234');
      await profiles.create('B', '1234');
      await expectLater(profiles.rename(a.id, 'b'), throwsA(isA<ProfileException>()));
      await profiles.rename(a.id, 'Alpha');
      expect((await profiles.byId(a.id))!.name, 'Alpha');
    });
  });

  group('playlists', () {
    late Profile ann;
    late Profile bob;
    setUp(() async {
      ann = await profiles.create('Ann', '1234');
      bob = await profiles.create('Bob', '1234');
    });

    test('create, add, list, count, order', () async {
      final id = await playlists.create(ann.id, 'Road trip');
      expect(await playlists.addTracks(ann.id, id, [t('a'), t('b'), t('c')]), 3);
      await playlists.addTracks(ann.id, id, [t('d')]);
      final info = (await playlists.list(ann.id)).single;
      expect((info.name, info.count), ('Road trip', 4));
      final items = await playlists.items(ann.id, id);
      expect(items.map((e) => e.track.title), ['a', 'b', 'c', 'd']);
      expect(items.first.track.channel, 'ch');
      expect(items.first.track.duration, 60);
    });

    test('profiles only see and touch their own playlists', () async {
      final id = await playlists.create(ann.id, 'Private');
      await playlists.addTracks(ann.id, id, [t('a')]);
      expect(await playlists.list(bob.id), isEmpty);
      await expectLater(playlists.items(bob.id, id), throwsStateError);
      await expectLater(playlists.addTracks(bob.id, id, [t('x')]), throwsStateError);
      await expectLater(playlists.rename(bob.id, id, 'Mine now'), throwsStateError);
      await expectLater(playlists.reorder(bob.id, id, [1]), throwsStateError);
      await playlists.delete(bob.id, id); // silently does nothing
      expect((await playlists.list(ann.id)).single.name, 'Private');
      expect(await playlists.items(ann.id, id), hasLength(1));
    });

    test('remove an item and reorder', () async {
      final id = await playlists.create(ann.id, 'P');
      await playlists.addTracks(ann.id, id, [t('a'), t('b'), t('c')]);
      var items = await playlists.items(ann.id, id);
      await playlists.removeItem(ann.id, id, items[1].itemId);
      items = await playlists.items(ann.id, id);
      expect(items.map((e) => e.track.title), ['a', 'c']);
      await playlists.reorder(ann.id, id, [items[1].itemId, items[0].itemId]);
      expect((await playlists.items(ann.id, id)).map((e) => e.track.title), ['c', 'a']);
      await playlists.addTracks(ann.id, id, [t('z')]);
      expect((await playlists.items(ann.id, id)).map((e) => e.track.title), ['c', 'a', 'z']);
    });

    test('the same song twice is allowed; rename and delete work', () async {
      final id = await playlists.create(ann.id, 'P');
      await playlists.addTracks(ann.id, id, [t('a'), t('a')]);
      expect(await playlists.items(ann.id, id), hasLength(2));
      await playlists.rename(ann.id, id, 'Renamed');
      expect((await playlists.list(ann.id)).single.name, 'Renamed');
      await playlists.delete(ann.id, id);
      expect(await playlists.list(ann.id), isEmpty);
      expect(await db.query('playlist_items'), isEmpty);
    });
  });

  test('revision goes up on every change so screens can reload', () async {
    final p = await profiles.create('Ann', '1234');
    var seen = 0;
    playlists.revision.addListener(() => seen++);
    final id = await playlists.create(p.id, 'P');
    await playlists.addTracks(p.id, id, [t('a'), t('b')]);
    final items = await playlists.items(p.id, id);
    await playlists.reorder(p.id, id, items.reversed.map((e) => e.itemId).toList());
    await playlists.removeItem(p.id, id, items.first.itemId);
    await playlists.rename(p.id, id, 'Q');
    await playlists.delete(p.id, id);
    expect(seen, 6);
    await playlists.list(p.id); // reading does not count
    expect(seen, 6);
  });

  test('kv stores per profile and overwrites', () async {
    final a = await profiles.create('A', '1234');
    final b = await profiles.create('B', '1234');
    final kv = KvRepo(db);
    await kv.set(a.id, 'queue', '1');
    await kv.set(a.id, 'queue', '2');
    await kv.set(b.id, 'queue', '3');
    expect(await kv.get(a.id, 'queue'), '2');
    expect(await kv.get(b.id, 'queue'), '3');
    expect(await kv.get(a.id, 'nothing'), isNull);
  });
}
