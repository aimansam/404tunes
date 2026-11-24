import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tunes404/player/queue_model.dart';
import 'package:tunes404/yt/models.dart';

Track t(String n) => Track(id: n.padRight(11, '_'), title: n);
List<String> titles(QueueModel q) => q.items.map((e) => e.track.title).toList();

void main() {
  QueueModel make([int n = 5]) {
    final q = QueueModel(random: Random(7));
    q.setQueue([for (var i = 0; i < n; i++) t('s$i')]);
    return q;
  }

  test('plays forward and stops at the end with repeat off', () {
    final q = make(3);
    expect(q.current!.track.title, 's0');
    expect(q.next(), isTrue);
    expect(q.next(), isTrue);
    expect(q.current!.track.title, 's2');
    expect(q.upNext, isNull);
    expect(q.next(), isFalse);
    expect(q.current!.track.title, 's2');
  });

  test('repeat all wraps around, previous wraps backwards', () {
    final q = make(3)..repeat = Repeat.all;
    q.jumpTo(2);
    expect(q.upNext!.track.title, 's0');
    expect(q.next(), isTrue);
    expect(q.current!.track.title, 's0');
    expect(q.previous(), isTrue);
    expect(q.current!.track.title, 's2');
  });

  test('previous at the start with repeat off stays put', () {
    final q = make(3);
    expect(q.previous(), isFalse);
    expect(q.position, 0);
  });

  test('setQueue starts at the chosen index', () {
    final q = QueueModel()..setQueue([t('a'), t('b'), t('c')], start: 2);
    expect(q.current!.track.title, 'c');
    expect(q.upNext, isNull);
  });

  group('editing', () {
    test('add appends, playNext inserts after current', () {
      final q = make(3);
      q.add(t('end'));
      q.playNext(t('soon'));
      expect(titles(q), ['s0', 'soon', 's1', 's2', 'end']);
    });

    test('the same song can be queued twice and removed separately', () {
      final q = make(2);
      q.add(t('s0'));
      expect(q.items.where((e) => e.track.title == 's0').length, 2);
      q.removeAt(2);
      expect(titles(q), ['s0', 's1']);
    });

    test('removing before the current keeps the current song', () {
      final q = make(4)..jumpTo(2);
      expect(q.removeAt(0), isFalse);
      expect(q.current!.track.title, 's2');
      expect(q.position, 1);
    });

    test('removing the current song reports it and moves on', () {
      final q = make(4)..jumpTo(1);
      expect(q.removeAt(1), isTrue);
      expect(q.current!.track.title, 's2');
    });

    test('removing the last song when it is current falls back to the new last', () {
      final q = make(3)..jumpTo(2);
      expect(q.removeAt(2), isTrue);
      expect(q.current!.track.title, 's1');
      q.removeAt(0);
      q.removeAt(0);
      expect(q.isEmpty, isTrue);
      expect(q.current, isNull);
      expect(q.position, -1);
    });

    test('move keeps the current song current', () {
      final q = make(4)..jumpTo(1);
      q.move(3, 0);
      expect(titles(q), ['s3', 's0', 's1', 's2']);
      expect(q.current!.track.title, 's1');
      q.move(1, 3);
      expect(q.current!.track.title, 's1');
    });

    test('clearUpcoming keeps only the current song', () {
      final q = make(4)..jumpTo(2);
      q.clearUpcoming();
      expect(titles(q), ['s2']);
      expect(q.position, 0);
    });
  });

  group('shuffle', () {
    test('keeps played songs and the current one, shuffles the rest', () {
      final q = make(30)..jumpTo(3);
      q.setShuffle(true);
      expect(q.shuffle, isTrue);
      expect(titles(q).take(4), ['s0', 's1', 's2', 's3']);
      expect(q.current!.track.title, 's3');
      expect(titles(q).skip(4).toSet(), {for (var i = 4; i < 30; i++) 's$i'});
      expect(titles(q).skip(4).toList(), isNot([for (var i = 4; i < 30; i++) 's$i']));
    });

    test('switching it off restores the original order, even after edits', () {
      final q = make(10);
      q.setShuffle(true);
      q.add(t('late'));
      q.removeAt(q.items.indexWhere((e) => e.track.title == 's5'));
      q.next();
      final now = q.current!.track.title;
      q.setShuffle(false);
      expect(q.shuffle, isFalse);
      expect(titles(q), ['s0', 's1', 's2', 's3', 's4', 's6', 's7', 's8', 's9', 'late']);
      expect(q.current!.track.title, now);
    });

    test('repeat all in shuffle reshuffles and never repeats the same song back to back', () {
      final q = QueueModel(random: Random(3));
      q.setQueue([for (var i = 0; i < 6; i++) t('s$i')], shuffled: true);
      q.repeat = Repeat.all;
      var last = q.current!.uid;
      for (var i = 0; i < 40; i++) {
        q.next();
        expect(q.current!.uid, isNot(last));
        last = q.current!.uid;
      }
    });
  });

  test('toJson / restore round trip keeps position, shuffle flag and repeat', () {
    final q = make(4)..jumpTo(2);
    q.repeat = Repeat.one;
    final json = q.toJson();
    final r = QueueModel()..restore(json);
    expect(titles(r), titles(q));
    expect(r.position, 2);
    expect(r.repeat, Repeat.one);
    expect(r.current!.track.id, q.current!.track.id);
  });

  test('restore survives garbage', () {
    final r = QueueModel()..restore({'tracks': 'nope', 'pos': 'x'});
    expect(r.isEmpty, isTrue);
    expect(r.current, isNull);
  });
}
