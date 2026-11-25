import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Where [DiscordRpc] sends the activity. The service talks to this, so tests can swap in a fake.
abstract class ActivitySink {
  /// Shows [activity]. Returns false when Discord isn't reachable.
  Future<bool> setActivity(Map<String, Object?> activity);
  Future<void> clearActivity();
  Future<void> disconnect();
}

/// A raw byte pipe to the Discord desktop app.
abstract class IpcChannel {
  Future<void> write(List<int> bytes);

  /// Reads exactly [n] bytes; throws when the connection closed.
  Future<Uint8List> read(int n);
  Future<void> close();
}

/// Opens a channel to a running Discord, or returns null when none is found.
typedef IpcConnector = Future<IpcChannel?> Function();

// Opcodes of Discord's local IPC framing: [u32 opcode LE][u32 length LE][JSON].
const _opHandshake = 0, _opFrame = 1, _opClose = 2, _opPing = 3, _opPong = 4;

/// A minimal Discord Rich Presence client: talks to the Discord desktop app over its local socket
/// (unix socket on Linux and macOS, named pipe on Windows). No server and no login involved.
///
/// Requests are strictly one at a time (send, then wait for the answer), which is all presence needs.
class DiscordRpc implements ActivitySink {
  DiscordRpc({required String clientId, IpcConnector? connector, int? processId, this.timeout = const Duration(seconds: 5)})
      : _clientId = clientId,
        _connector = connector ?? connectToDiscord,
        _pid = processId ?? pid;

  String _clientId;
  final IpcConnector _connector;
  final int _pid;
  final Duration timeout;

  IpcChannel? _channel;
  Future<void> _queue = Future.value();
  int _nonce = 0;

  /// Last error text from Discord or the connection, for the settings screen.
  String? lastError;

  bool get connected => _channel != null;

  String get clientId => _clientId;
  set clientId(String v) {
    if (v == _clientId) return;
    _clientId = v;
    unawaited(disconnect()); // the next update reconnects with the new application
  }

  Future<T> _serial<T>(Future<T> Function() job) {
    final done = _queue.then((_) => job());
    _queue = done.then((_) {}, onError: (_) {});
    return done;
  }

  @override
  Future<bool> setActivity(Map<String, Object?> activity) => _command(activity);

  @override
  Future<void> clearActivity() async {
    if (_channel == null) return; // nothing is showing
    await _command(null);
  }

  Future<bool> _command(Map<String, Object?>? activity) => _serial(() async {
        try {
          final ch = _channel ?? await _connect();
          if (ch == null) return false;
          final nonce = '${++_nonce}';
          await _send(ch, _opFrame, {
            'cmd': 'SET_ACTIVITY',
            'args': {'pid': _pid, 'activity': activity},
            'nonce': nonce,
          });
          final reply = await _readReply(ch, nonce);
          if (reply['evt'] == 'ERROR') {
            lastError = (reply['data'] as Map?)?['message']?.toString() ?? 'Discord refused the activity';
            return false;
          }
          lastError = null;
          return true;
        } catch (e) {
          lastError = '$e';
          await _drop();
          return false;
        }
      });

  Future<IpcChannel?> _connect() async {
    if (_clientId.isEmpty) {
      lastError = 'No Discord application ID set';
      return null;
    }
    final ch = await _connector();
    if (ch == null) {
      lastError = 'Discord is not running';
      return null;
    }
    try {
      await _send(ch, _opHandshake, {'v': 1, 'client_id': _clientId});
      final (op, data) = await _readFrame(ch);
      if (op == _opClose || data['evt'] == 'ERROR') {
        throw StateError(data['message']?.toString() ?? 'Discord closed the connection (check the application ID)');
      }
      if (data['evt'] != 'READY') throw StateError('Unexpected answer from Discord');
    } catch (_) {
      await ch.close().catchError((_) {});
      rethrow;
    }
    return _channel = ch;
  }

  Future<void> _send(IpcChannel ch, int op, Map<String, Object?> payload) {
    final body = utf8.encode(jsonEncode(payload));
    final head = ByteData(8)
      ..setUint32(0, op, Endian.little)
      ..setUint32(4, body.length, Endian.little);
    return ch.write([...head.buffer.asUint8List(), ...body]).timeout(timeout);
  }

  Future<(int, Map<String, dynamic>)> _readFrame(IpcChannel ch) async {
    final head = ByteData.sublistView(await ch.read(8).timeout(timeout));
    final op = head.getUint32(0, Endian.little);
    final len = head.getUint32(4, Endian.little);
    if (len > 1 << 20) throw StateError('Bad frame from Discord');
    final body = len == 0 ? Uint8List(0) : await ch.read(len).timeout(timeout);
    final json = len == 0 ? <String, dynamic>{} : jsonDecode(utf8.decode(body));
    return (op, json is Map ? json.cast<String, dynamic>() : <String, dynamic>{});
  }

  /// Waits for the answer to [nonce], answering Discord's pings on the way.
  Future<Map<String, dynamic>> _readReply(IpcChannel ch, String nonce) async {
    for (var i = 0; i < 16; i++) {
      final (op, data) = await _readFrame(ch);
      if (op == _opPing) {
        await _send(ch, _opPong, data);
      } else if (op == _opClose) {
        throw StateError(data['message']?.toString() ?? 'Discord closed the connection');
      } else if (op == _opFrame && (data['nonce'] == nonce || data['nonce'] == null && data['cmd'] == 'SET_ACTIVITY')) {
        return data;
      }
      // anything else (events we did not ask for) is skipped
    }
    throw StateError('No answer from Discord');
  }

  Future<void> _drop() async {
    final ch = _channel;
    _channel = null;
    if (ch != null) await ch.close().catchError((_) {});
  }

  /// Hangs up; the activity disappears from the profile.
  @override
  Future<void> disconnect() => _serial(_drop);
}

// ------------------------------------------------------------------ finding Discord

/// Folders that may hold Discord's `discord-ipc-N` sockets on Linux and macOS, including the Flatpak and Snap ones.
List<String> unixSocketPaths(Map<String, String> env) {
  final dirs = <String>{
    for (final k in const ['XDG_RUNTIME_DIR', 'TMPDIR', 'TMP', 'TEMP'])
      if ((env[k] ?? '').isNotEmpty) env[k]!.replaceFirst(RegExp(r'/+$'), ''),
    '/tmp',
  };
  return [
    for (final d in dirs)
      for (final sub in const ['', '/app/com.discordapp.Discord', '/snap.discord'])
        for (var i = 0; i < 10; i++) '$d$sub/discord-ipc-$i',
  ];
}

/// Connects to whichever Discord is running, or returns null.
Future<IpcChannel?> connectToDiscord() async {
  if (Platform.isWindows) {
    for (var i = 0; i < 10; i++) {
      try {
        final f = await File(r'\\.\pipe\discord-ipc-' '$i').open(mode: FileMode.append);
        return _FileChannel(f);
      } catch (_) {}
    }
    return null;
  }
  return connectToUnixPaths(unixSocketPaths(Platform.environment));
}

Future<IpcChannel?> connectToUnixPaths(List<String> paths) async {
  for (final path in paths) {
    try {
      if (FileSystemEntity.typeSync(path) != FileSystemEntityType.unixDomainSock) continue;
      final socket = await Socket.connect(InternetAddress(path, type: InternetAddressType.unix), 0);
      return SocketChannel(socket);
    } catch (_) {}
  }
  return null;
}

/// [IpcChannel] over a unix-domain socket.
class SocketChannel implements IpcChannel {
  SocketChannel(this._socket) {
    _socket.listen(
      (d) {
        _data = Uint8List.fromList([..._data, ...d]);
        _wake();
      },
      onError: (Object e) {
        _error ??= e;
        _wake();
      },
      onDone: () {
        _error ??= StateError('Discord closed the connection');
        _wake();
      },
      cancelOnError: true,
    );
  }

  final Socket _socket;
  Uint8List _data = Uint8List(0);
  Object? _error;
  Completer<void>? _waiting;

  void _wake() {
    final w = _waiting;
    _waiting = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  @override
  Future<void> write(List<int> bytes) async {
    _socket.add(bytes);
    await _socket.flush();
  }

  @override
  Future<Uint8List> read(int n) async {
    while (_data.length < n) {
      if (_error != null) throw _error!;
      _waiting = Completer<void>();
      await _waiting!.future;
    }
    final out = Uint8List.sublistView(_data, 0, n);
    _data = Uint8List.sublistView(_data, n);
    return Uint8List.fromList(out);
  }

  @override
  Future<void> close() async {
    _socket.destroy();
  }
}

/// [IpcChannel] over a Windows named pipe, opened as a file.
class _FileChannel implements IpcChannel {
  _FileChannel(this._file);
  final RandomAccessFile _file;

  @override
  Future<void> write(List<int> bytes) async {
    await _file.writeFrom(bytes);
    await _file.flush();
  }

  @override
  Future<Uint8List> read(int n) async {
    final out = BytesBuilder(copy: false);
    while (out.length < n) {
      final chunk = await _file.read(n - out.length);
      if (chunk.isEmpty) throw StateError('Discord closed the connection');
      out.add(chunk);
    }
    return out.takeBytes();
  }

  @override
  Future<void> close() => _file.close();
}
