import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tunes404/presence/discord_rpc.dart';

/// A stand-in for the Discord desktop app: listens on a unix socket and speaks its IPC framing.
class FakeDiscord {
  FakeDiscord._(this.server, this.path);
  final ServerSocket server;
  final String path;
  final received = <(int, Map<String, dynamic>)>[];

  bool rejectHandshake = false;
  bool pingBeforeReply = false;
  bool errorOnActivity = false;
  Socket? client;

  static Future<FakeDiscord> start(String path) async {
    final server = await ServerSocket.bind(InternetAddress(path, type: InternetAddressType.unix), 0);
    final d = FakeDiscord._(server, path);
    server.listen(d._onClient);
    return d;
  }

  void _onClient(Socket s) {
    client = s;
    var buf = Uint8List(0);
    s.listen((chunk) {
      buf = Uint8List.fromList([...buf, ...chunk]);
      while (buf.length >= 8) {
        final h = ByteData.sublistView(buf);
        final op = h.getUint32(0, Endian.little), len = h.getUint32(4, Endian.little);
        if (buf.length < 8 + len) break;
        final json = jsonDecode(utf8.decode(buf.sublist(8, 8 + len))) as Map<String, dynamic>;
        buf = Uint8List.sublistView(buf, 8 + len);
        received.add((op, json));
        _answer(s, op, json);
      }
    }, onError: (_) {});
  }

  void _send(Socket s, int op, Map<String, Object?> payload) {
    final body = utf8.encode(jsonEncode(payload));
    final head = ByteData(8)
      ..setUint32(0, op, Endian.little)
      ..setUint32(4, body.length, Endian.little);
    s.add([...head.buffer.asUint8List(), ...body]);
  }

  void _answer(Socket s, int op, Map<String, dynamic> json) {
    if (op == 0) {
      if (rejectHandshake) {
        _send(s, 2, {'code': 4000, 'message': 'Invalid Client ID'});
      } else {
        _send(s, 1, {'cmd': 'DISPATCH', 'evt': 'READY', 'data': {'v': 1}});
      }
    } else if (op == 1 && json['cmd'] == 'SET_ACTIVITY') {
      if (pingBeforeReply) _send(s, 3, {'nonce': 'ping'});
      if (errorOnActivity) {
        _send(s, 1, {'cmd': 'SET_ACTIVITY', 'evt': 'ERROR', 'data': {'code': 4000, 'message': 'bad activity'}, 'nonce': json['nonce']});
      } else {
        _send(s, 1, {'cmd': 'SET_ACTIVITY', 'evt': null, 'data': {}, 'nonce': json['nonce']});
      }
    }
  }

  List<Map<String, dynamic>> get activityCommands =>
      [for (final (op, j) in received) if (op == 1 && j['cmd'] == 'SET_ACTIVITY') j];

  Future<void> stop() async {
    client?.destroy();
    await server.close();
  }
}

void main() {
  if (Platform.isWindows) return; // these tests use a unix socket; Windows talks over a named pipe

  late Directory dir;
  late String path;
  FakeDiscord? discord;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('d404');
    path = '${dir.path}/discord-ipc-0';
  });
  tearDown(() async {
    await discord?.stop();
    discord = null;
    dir.deleteSync(recursive: true);
  });

  DiscordRpc rpc({String id = '1234567890'}) =>
      DiscordRpc(clientId: id, processId: 42, connector: () => connectToUnixPaths([path]), timeout: const Duration(seconds: 2));

  test('handshake carries the application id; activity goes out with our pid', () async {
    discord = await FakeDiscord.start(path);
    final r = rpc();
    expect(await r.setActivity({'type': 2, 'details': 'Song'}), isTrue);
    expect(r.connected, isTrue);
    expect(discord!.received.first.$1, 0);
    expect(discord!.received.first.$2, {'v': 1, 'client_id': '1234567890'});
    final cmd = discord!.activityCommands.single;
    expect(cmd['args']['pid'], 42);
    expect(cmd['args']['activity'], {'type': 2, 'details': 'Song'});
    // a second update reuses the connection
    expect(await r.setActivity({'type': 2, 'details': 'Next'}), isTrue);
    expect(discord!.received.where((e) => e.$1 == 0), hasLength(1));
    expect(discord!.activityCommands, hasLength(2));
    await r.disconnect();
    expect(r.connected, isFalse);
  });

  test('clear sends a null activity, and does nothing when nothing is showing', () async {
    discord = await FakeDiscord.start(path);
    final r = rpc();
    await r.clearActivity();
    expect(discord!.received, isEmpty);
    await r.setActivity({'details': 'x1'});
    await r.clearActivity();
    expect(discord!.activityCommands.last['args']['activity'], isNull);
    await r.disconnect();
  });

  test('answers Discord pings while waiting for a reply', () async {
    discord = await FakeDiscord.start(path);
    discord!.pingBeforeReply = true;
    final r = rpc();
    expect(await r.setActivity({'details': 'x1'}), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(discord!.received.where((e) => e.$1 == 4), hasLength(1)); // PONG
    await r.disconnect();
  });

  test('a wrong application id is reported, not thrown', () async {
    discord = await FakeDiscord.start(path);
    discord!.rejectHandshake = true;
    final r = rpc(id: '1');
    expect(await r.setActivity({'details': 'x1'}), isFalse);
    expect(r.connected, isFalse);
    expect(r.lastError, contains('Invalid Client ID'));
  });

  test('Discord answering with an error keeps the connection but reports it', () async {
    discord = await FakeDiscord.start(path);
    discord!.errorOnActivity = true;
    final r = rpc();
    expect(await r.setActivity({'details': 'x1'}), isFalse);
    expect(r.lastError, contains('bad activity'));
    expect(r.connected, isTrue);
    await r.disconnect();
  });

  test('Discord not running: false, then works once it starts', () async {
    final r = rpc();
    expect(await r.setActivity({'details': 'x1'}), isFalse);
    expect(r.lastError, contains('not running'));
    discord = await FakeDiscord.start(path);
    expect(await r.setActivity({'details': 'x1'}), isTrue);
    await r.disconnect();
  });

  test('Discord quits mid-session: the next update fails cleanly and reconnects after it is back', () async {
    discord = await FakeDiscord.start(path);
    final r = rpc();
    expect(await r.setActivity({'details': 'x1'}), isTrue);
    await discord!.stop();
    expect(await r.setActivity({'details': 'x2'}), isFalse);
    expect(r.connected, isFalse);
    discord = await FakeDiscord.start(path);
    expect(await r.setActivity({'details': 'x3'}), isTrue);
    await r.disconnect();
  });

  test('no application id: nothing is sent', () async {
    discord = await FakeDiscord.start(path);
    final r = rpc(id: '');
    expect(await r.setActivity({'details': 'x1'}), isFalse);
    expect(r.lastError, contains('application ID'));
    expect(discord!.received, isEmpty);
  });

  test('changing the application id reconnects with the new one', () async {
    discord = await FakeDiscord.start(path);
    final r = rpc(id: '111');
    await r.setActivity({'details': 'x1'});
    r.clientId = '222';
    await r.setActivity({'details': 'x2'});
    final handshakes = discord!.received.where((e) => e.$1 == 0).map((e) => e.$2['client_id']).toList();
    expect(handshakes, ['111', '222']);
    await r.disconnect();
  });

  test('socket search covers XDG, TMPDIR, Flatpak and Snap locations', () {
    final paths = unixSocketPaths({'XDG_RUNTIME_DIR': '/run/user/1000/', 'TMPDIR': '/var/tmp'});
    expect(paths, contains('/run/user/1000/discord-ipc-0'));
    expect(paths, contains('/run/user/1000/app/com.discordapp.Discord/discord-ipc-0'));
    expect(paths, contains('/run/user/1000/snap.discord/discord-ipc-9'));
    expect(paths, contains('/var/tmp/discord-ipc-3'));
    expect(paths, contains('/tmp/discord-ipc-0'));
    expect(paths.toSet().length, paths.length); // no duplicates
  });
}
