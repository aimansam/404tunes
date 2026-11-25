import 'package:flutter_test/flutter_test.dart';
import 'package:tunes404/presence/discord_rpc.dart';
import 'package:tunes404/presence/presence_service.dart';
import 'package:tunes404/yt/models.dart';

class FakeSink implements ActivitySink {
  final calls = <String>[];
  final activities = <Map<String, Object?>>[];
  bool reachable = true;

  @override
  Future<bool> setActivity(Map<String, Object?> activity) async {
    calls.add('set');
    if (!reachable) return false;
    activities.add(activity);
    return true;
  }

  @override
  Future<void> clearActivity() async => calls.add('clear');
  @override
  Future<void> disconnect() async => calls.add('disconnect');
}

const song = Track(id: 'abcdefghijk', title: 'Blue in Green', channel: 'Miles Davis - Topic', duration: 337);

void main() {
  group('buildActivity', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1700000000000);

    test('listening activity with a progress bar and the YouTube thumbnail', () {
      final a = buildActivity(const NowPlaying(song, playing: true, position: Duration(seconds: 20)), now: now);
      expect(a['type'], 2);
      expect(a['details'], 'Blue in Green');
      expect(a['state'], 'Miles Davis'); // "- Topic" removed
      final ts = a['timestamps'] as Map;
      expect(ts['start'], 1700000000 - 20);
      expect(ts['end'], 1700000000 - 20 + 337);
      expect((a['assets'] as Map)['large_image'], 'https://i.ytimg.com/vi/abcdefghijk/mqdefault.jpg');
    });

    test('no end time without a duration, no state without a channel', () {
      final a = buildActivity(const NowPlaying(Track(id: 'abcdefghijk', title: 'Live thing'), playing: true, position: Duration.zero), now: now);
      expect((a['timestamps'] as Map).containsKey('end'), isFalse);
      expect(a.containsKey('state'), isFalse);
    });

    test('fields obey Discord\'s 2 to 128 character rule', () {
      final long = buildActivity(NowPlaying(Track(id: 'abcdefghijk', title: 'x' * 300, channel: 'y'), playing: true, position: Duration.zero), now: now);
      expect((long['details'] as String).length, 128);
      expect((long['state'] as String).length, greaterThanOrEqualTo(2));
    });
  });

  group('PresenceService', () {
    late FakeSink sink;
    late NowPlaying? np;
    late bool on;
    late DateTime clock;
    late PresenceService svc;

    setUp(() {
      sink = FakeSink();
      np = null;
      on = true;
      clock = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      svc = PresenceService(
        sink: sink,
        read: () => np,
        enabled: () => on,
        debounce: const Duration(milliseconds: 5),
        retryAfter: const Duration(hours: 1),
        seekCheck: const Duration(hours: 1),
        clock: () => clock,
      );
    });
    tearDown(() => svc.dispose());

    Future<void> poke() async {
      svc.poke();
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }

    test('shows the song while it plays, clears on pause', () async {
      np = const NowPlaying(song, playing: true, position: Duration(seconds: 3));
      await poke();
      expect(sink.calls, ['set']);
      expect(svc.status.value, PresenceStatus.showing);
      np = const NowPlaying(song, playing: false, position: Duration(seconds: 9));
      await poke();
      expect(sink.calls, ['set', 'clear']);
      expect(svc.status.value, PresenceStatus.idle);
    });

    test('nothing playing: nothing to clear, nothing sent', () async {
      await poke();
      expect(sink.calls, isEmpty);
      expect(svc.status.value, PresenceStatus.idle);
    });

    test('the same song is not sent twice, but a seek is', () async {
      np = const NowPlaying(song, playing: true, position: Duration(seconds: 3));
      await poke();
      clock = clock.add(const Duration(seconds: 2)); // time passes, position follows: same start
      np = const NowPlaying(song, playing: true, position: Duration(seconds: 5));
      await poke();
      expect(sink.calls, ['set']);
      np = const NowPlaying(song, playing: true, position: Duration(seconds: 120)); // seeked
      await poke();
      expect(sink.calls, ['set', 'set']);
      expect((sink.activities.last['timestamps'] as Map)['start'], 1700000000 + 2 - 120);
    });

    test('a new song replaces the old one', () async {
      np = const NowPlaying(song, playing: true, position: Duration.zero);
      await poke();
      np = const NowPlaying(Track(id: 'zzzzzzzzzzz', title: 'So What', channel: 'Miles Davis'), playing: true, position: Duration.zero);
      await poke();
      expect(sink.activities.map((a) => a['details']), ['Blue in Green', 'So What']);
    });

    test('turning it off clears and disconnects', () async {
      np = const NowPlaying(song, playing: true, position: Duration.zero);
      await poke();
      on = false;
      await poke();
      expect(sink.calls, ['set', 'clear', 'disconnect']);
      expect(svc.status.value, PresenceStatus.off);
    });

    test('Discord unreachable: reports it and does not retry on every change', () async {
      sink.reachable = false;
      np = const NowPlaying(song, playing: true, position: Duration.zero);
      await poke();
      expect(svc.status.value, PresenceStatus.unavailable);
      await poke();
      await poke();
      expect(sink.calls, ['set']); // backed off
      // once the back-off is over and Discord is there, it shows up
      sink.reachable = true;
      clock = clock.add(const Duration(hours: 2));
      await poke();
      expect(svc.status.value, PresenceStatus.showing);
      expect(sink.calls, ['set', 'set']);
    });
  });
}
