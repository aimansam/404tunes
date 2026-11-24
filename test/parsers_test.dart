import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tunes404/yt/models.dart';
import 'package:tunes404/yt/parsers.dart';

Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map<String, dynamic>;

void main() {
  group('parseSearch (real yt-dlp output)', () {
    test('keeps playable videos and drops live streams', () {
      final raw = fixture('search.json');
      final all = (raw['entries'] as List).length;
      final out = parseSearch(raw);
      expect(out, isNotEmpty);
      expect(out.length, lessThan(all), reason: 'the lofi radio livestream must be filtered out');
      for (final t in out) {
        expect(isVideoId(t.id), isTrue);
        expect(t.duration, greaterThan(0));
        expect(t.title, isNotEmpty);
      }
    });

    test('drops upcoming, live and duration-less entries', () {
      final out = parseSearch({
        'entries': [
          {'id': 'aaaaaaaaaaa', 'title': 'ok', 'duration': 100, 'channel': 'c'},
          {'id': 'bbbbbbbbbbb', 'title': 'live', 'duration': 100, 'live_status': 'is_live'},
          {'id': 'ccccccccccc', 'title': 'soon', 'duration': 100, 'live_status': 'is_upcoming'},
          {'id': 'ddddddddddd', 'title': 'nodur'},
          {'id': 'short', 'title': 'bad id', 'duration': 5},
          null,
        ]
      });
      expect(out.map((t) => t.id), ['aaaaaaaaaaa']);
      expect(out.single.channel, 'c');
    });
  });

  group('parsePlaylistSearch', () {
    test('real results give list ids, titles and a thumbnail video id', () {
      final out = parsePlaylistSearch(fixture('playlist_search.json'));
      expect(out, isNotEmpty);
      for (final r in out) {
        expect(isListId(r.listId), isTrue);
        expect(r.title, isNotEmpty);
      }
      expect(out.first.thumbVideoId, matches(RegExp(r'^[\w-]{11}$')));
    });

    test('ignores entries that are not playlists', () {
      final out = parsePlaylistSearch({
        'entries': [
          {'id': 'aaaaaaaaaaa', 'title': 'video', 'url': 'https://www.youtube.com/watch?v=aaaaaaaaaaa'},
        ]
      });
      expect(out, isEmpty);
    });
  });

  group('parsePlaylist', () {
    test('real playlist: title and tracks, private videos removed', () {
      final raw = fixture('playlist.json');
      final out = parsePlaylist(raw);
      expect(out.title, 'Popular Music Videos');
      expect(out.items, isNotEmpty);
      expect(out.items.any((t) => t.title == '[Private video]'), isFalse);
      expect((raw['entries'] as List).length, out.items.length + 1);
    });
  });

  group('parseResolve', () {
    test('real resolve output: url, headers, expiry from the url', () {
      final s = parseResolve(fixture('resolve.json'), now: DateTime(2026, 1, 1));
      expect(s.url, startsWith('https://'));
      expect(s.track.id, 'dQw4w9WgXcQ');
      expect(s.track.duration, 213);
      expect(s.headers, isNotEmpty);
      // expire=4102444800 (2100-01-01), minus the 10 minute safety margin
      expect(s.expiresAt, DateTime.fromMillisecondsSinceEpoch(4102444800 * 1000).subtract(const Duration(minutes: 10)));
      expect(s.isFresh, isTrue);
    });

    test('url without expire is valid for 3 hours', () {
      final now = DateTime(2026, 1, 1, 12);
      final s = parseResolve({
        'id': 'aaaaaaaaaaa',
        'title': 't',
        'url': 'https://example.com/a.m4a',
        'protocol': 'https',
      }, now: now);
      expect(s.expiresAt, now.add(const Duration(hours: 3)));
    });

    test('live streams and non-http protocols are rejected', () {
      expect(() => parseResolve({'id': 'aaaaaaaaaaa', 'is_live': true, 'url': 'https://x'}),
          throwsA(isA<UnplayableException>()));
      expect(
          () => parseResolve({'id': 'aaaaaaaaaaa', 'url': 'https://x', 'protocol': 'm3u8_native'}),
          throwsA(isA<UnplayableException>()));
    });

    test('available_at in the future is kept', () {
      final s = parseResolve({
        'id': 'aaaaaaaaaaa',
        'url': 'https://x/a',
        'available_at': 4102444800,
      });
      expect(s.availableAt, DateTime.fromMillisecondsSinceEpoch(4102444800 * 1000));
    });
  });
}
