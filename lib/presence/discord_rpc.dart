import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Where [DiscordRpc] sends the activity. The service talks to this, so tests can swap in a fake.
abstract class ActivitySink {
  /// Shows [activity]. Returns false when Discord isn't reachable.
  Future<bool> setActivity(Map<String, Object?> activity);
  Future<void> clearActivity();
  Future<void> disconnect();

  /// Why the last attempt failed, for the settings screen.
  String? get lastError;
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
  @override
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

/// Connects to whichever Discord is running, or returns null. Throws when Discord seems to be there but refuses.
Future<IpcChannel?> connectToDiscord() async {
  if (Platform.isWindows) return WindowsPipeChannel.connect();
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

// ------------------------------------------------------------------ Windows named pipe

typedef _CreateFileC = IntPtr Function(Pointer<Utf16>, Uint32, Uint32, Pointer<Void>, Uint32, Uint32, IntPtr);
typedef _CreateFileD = int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int);
typedef _IoC = Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>);
typedef _IoD = int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>);
typedef _PeekC = Int32 Function(IntPtr, Pointer<Void>, Uint32, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>);
typedef _PeekD = int Function(int, Pointer<Void>, int, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>);

/// [IpcChannel] over Discord's Windows named pipe, using the Win32 API directly. (Dart's own file API can't be used:
/// it seeks to the end of a file it opens for writing, which a pipe does not allow.)
/// Reading polls with PeekNamedPipe, so it never blocks the app's UI thread.
class WindowsPipeChannel implements IpcChannel {
  WindowsPipeChannel._(this._handle);
  int _handle;

  static const _genericRead = 0x80000000, _genericWrite = 0x40000000, _openExisting = 3;
  static const _errNotFound = 2, _errPathNotFound = 3;

  static final DynamicLibrary _k32 = DynamicLibrary.open('kernel32.dll');
  static final _createFile = _k32.lookupFunction<_CreateFileC, _CreateFileD>('CreateFileW');
  static final _readFile = _k32.lookupFunction<_IoC, _IoD>('ReadFile');
  static final _writeFile = _k32.lookupFunction<_IoC, _IoD>('WriteFile');
  static final _peek = _k32.lookupFunction<_PeekC, _PeekD>('PeekNamedPipe');
  static final _closeHandle = _k32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
  static final _lastError = _k32.lookupFunction<Uint32 Function(), int Function()>('GetLastError');

  /// Tries \\.\pipe\discord-ipc-0 to 9. Null when none exists (Discord is not running).
  static Future<IpcChannel?> connect() async {
    int? worst; // the most telling error that was not "no such pipe"
    for (var i = 0; i < 10; i++) {
      final name = '\\\\.\\pipe\\discord-ipc-$i'.toNativeUtf16();
      try {
        final h = _createFile(name, _genericRead | _genericWrite, 0, nullptr, _openExisting, 0, 0);
        if (h != -1) return WindowsPipeChannel._(h);
        final err = _lastError();
        if (err != _errNotFound && err != _errPathNotFound) worst ??= err;
      } finally {
        calloc.free(name);
      }
    }
    if (worst != null) {
      throw StateError(worst == 5
          ? 'Windows denied access to Discord (is one of the two apps running as administrator?)'
          : 'Could not open Discord\'s pipe (Windows error $worst)');
    }
    return null;
  }

  @override
  Future<void> write(List<int> bytes) async {
    final buf = calloc<Uint8>(bytes.length);
    final done = calloc<Uint32>();
    try {
      buf.asTypedList(bytes.length).setAll(0, bytes);
      var sent = 0;
      while (sent < bytes.length) {
        if (_handle == 0) throw StateError('Discord closed the connection');
        if (_writeFile(_handle, buf + sent, bytes.length - sent, done, nullptr) == 0) {
          throw StateError('Could not write to Discord (Windows error ${_lastError()})');
        }
        sent += done.value;
      }
    } finally {
      calloc.free(buf);
      calloc.free(done);
    }
  }

  @override
  Future<Uint8List> read(int n) async {
    final out = Uint8List(n);
    final avail = calloc<Uint32>();
    final got = calloc<Uint32>();
    final buf = calloc<Uint8>(n);
    try {
      var have = 0;
      while (have < n) {
        if (_handle == 0) throw StateError('Discord closed the connection');
        if (_peek(_handle, nullptr, 0, nullptr, avail, nullptr) == 0) {
          throw StateError('Discord closed the connection (Windows error ${_lastError()})');
        }
        if (avail.value == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          continue;
        }
        final want = avail.value < n - have ? avail.value : n - have;
        if (_readFile(_handle, buf, want, got, nullptr) == 0) {
          throw StateError('Could not read from Discord (Windows error ${_lastError()})');
        }
        out.setRange(have, have + got.value, buf.asTypedList(got.value));
        have += got.value;
      }
      return out;
    } finally {
      calloc.free(avail);
      calloc.free(got);
      calloc.free(buf);
    }
  }

  @override
  Future<void> close() async {
    final h = _handle;
    _handle = 0;
    if (h != 0) _closeHandle(h);
  }
}
