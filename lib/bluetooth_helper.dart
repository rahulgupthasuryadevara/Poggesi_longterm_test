import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

// ---------------------------------------------------------------------------
// BluetoothHelper
//
// Command pipeline (single-lane, serialized):
//
//   Caller → sendCommand(cmd)
//              └─► _writeQueue (List<_QueuedCommand>)
//                       └─► _pump() runs one write at a time
//                                └─► BLE write characteristic
//                                         └─► device notification
//                                                  └─► onDataReceived(msg)
//
// Why single-lane?
//   The Nordic UART BLE controller processes one command and responds before
//   the next one is expected. Sending two writes back-to-back (e.g. a motor
//   command and a position poll) without waiting causes the device to silently
//   drop the second packet. All callers (movement timer, position poll timer,
//   keep-alive) now go through the same queue so they never race.
//
// Priority:
//   Motor commands (up/down/idle/stop) use Priority.high and jump to the
//   front of the queue. Position reads use Priority.normal and sit behind
//   any pending motor command. This means even if the poll fires at the same
//   millisecond as a motor send, the motor command always wins.
//
// Keep-alive:
//   A 4-second timer sends "#CMD idle 0\n" only when the queue is empty and
//   no write is in flight. It can be paused (during automatic movement) and
//   resumed (at rest / pause / stop).
//
// Notification deduplication:
//   _discoverAndSubscribe() cancels the previous notify subscription before
//   creating a new one, so reconnects never accumulate duplicate listeners.
// ---------------------------------------------------------------------------

enum _Priority { high, normal }

class _QueuedCommand {
  final String cmd;
  final _Priority priority;
  _QueuedCommand(this.cmd, this.priority);
}

class BluetoothHelper {
  // ── Nordic UART Service UUIDs ────────────────────────────────────────────
  final Guid serviceUuid = Guid('6e400001-b5a3-f393-e0a9-e50e24dcca9e');
  final Guid writeUuid   = Guid('6e400002-b5a3-f393-e0a9-e50e24dcca9e');
  final Guid notifyUuid  = Guid('6e400003-b5a3-f393-e0a9-e50e24dcca9e');

  // ── BLE objects ──────────────────────────────────────────────────────────
  BluetoothDevice?           device;
  BluetoothCharacteristic?   writeChar;
  BluetoothCharacteristic?   notifyChar;
  StreamSubscription<List<int>>?              _notifySubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;

  // ── Callbacks ─────────────────────────────────────────────────────────────
  void Function(String msg)? onDataReceived;
  void Function(bool connected)? onConnectionStateChanged;

  // ── Write queue (single-lane, priority-aware) ────────────────────────────
  final List<_QueuedCommand> _writeQueue = [];
  bool _isPumping = false;

  // Minimum gap between consecutive writes (ms).
  // 50 ms is comfortable for NUS at 23-byte MTU; tighten if the device is faster.
  static const Duration _interWriteDelay = Duration(milliseconds: 50);

  // ── Keep-alive ───────────────────────────────────────────────────────────
  Timer? _keepAliveTimer;
  bool   _keepAlivePaused = false;

  // ── Reconnect guards ─────────────────────────────────────────────────────
  bool _isReconnecting  = false;
  bool _userDisconnected = false;

  // ── Convenience getters ──────────────────────────────────────────────────
  String get connectedDeviceName => device?.platformName ?? 'Unknown Device';

  Future<bool> get isActuallyConnected async {
    if (device == null) return false;
    final state = await device!.connectionState.first;
    return state == BluetoothConnectionState.connected;
  }

  // =========================================================================
  // Public API
  // =========================================================================

  /// Send any command. Motor commands should pass [highPriority]=true so they
  /// jump ahead of any pending position-read in the queue.
  Future<void> sendCommand(String cmd, {bool highPriority = false}) async {
    if (writeChar == null) return;
    final priority = highPriority ? _Priority.high : _Priority.normal;
    _enqueue(_QueuedCommand(cmd, priority));
  }

  /// Immediately clear the queue and send [stopCmd] — used for emergency stop.
  /// The stop command is written directly (bypassing the queue) so it is never
  /// delayed behind a pending position read.
  void emergencyStop(String stopCmd) {
    _writeQueue.clear();
    _isPumping = false; // allow the direct write below
    _directWrite(stopCmd);
  }

  void pauseKeepAlive() {
    _keepAlivePaused = true;
    _keepAliveTimer?.cancel();
  }

  void resumeKeepAlive() {
    _keepAlivePaused = false;
    _startKeepAliveTimer();
  }

  Future<void> disconnect() async {
    _userDisconnected = true;
    _keepAliveTimer?.cancel();
    _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    _notifySubscription?.cancel();
    _notifySubscription = null;
    _writeQueue.clear();
    _isPumping = false;

    if (device != null) {
      try {
        await device!.disconnect();
        if (kDebugMode) print('[BLE] Disconnected from device');
      } catch (e) {
        if (kDebugMode) print('[BLE] Error while disconnecting: $e');
      } finally {
        device    = null;
        writeChar = null;
        notifyChar = null;
      }
    }
  }

  // =========================================================================
  // Scan / connect
  // =========================================================================

  Future<void> startScan() async {
    final ok = await _requestBlePermissions();
    if (!ok) {
      if (kDebugMode) print('[BLE] Permissions not granted');
      return;
    }
    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      if (kDebugMode) print('[BLE] Bluetooth is OFF');
      return;
    }
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
  }

  Future<bool> connectToDevice(BluetoothDevice targetDevice) async {
    device            = targetDevice;
    _userDisconnected = false;
    _isReconnecting   = false;
    _writeQueue.clear();
    _isPumping = false;

    if (kDebugMode) print('[BLE] Connecting to ${device!.platformName}…');
    try {
      await device!.connect(autoConnect: false, mtu: 23);
    } catch (e) {
      if (kDebugMode) print('[BLE] Connection failed: $e');
      return false;
    }

    if (kDebugMode) print('[BLE] Connected to ${device!.platformName}');
    _listenToConnectionState();
    await _discoverAndSubscribe();
    _startKeepAliveTimer();
    return true;
  }

  // =========================================================================
  // Internal — write queue pump
  // =========================================================================

  void _enqueue(_QueuedCommand cmd) {
    if (cmd.priority == _Priority.high) {
      // Insert in front of any existing normal-priority items but after other
      // high-priority items already waiting (FIFO within same priority).
      final insertAt = _writeQueue.indexWhere((c) => c.priority == _Priority.normal);
      if (insertAt == -1) {
        _writeQueue.add(cmd);
      } else {
        _writeQueue.insert(insertAt, cmd);
      }
    } else {
      _writeQueue.add(cmd);
    }
    _pump();
  }

  Future<void> _pump() async {
    if (_isPumping || _writeQueue.isEmpty || writeChar == null) return;
    _isPumping = true;

    while (_writeQueue.isNotEmpty && writeChar != null) {
      final cmd = _writeQueue.removeAt(0);
      await _directWrite(cmd.cmd);
      // Small mandatory gap so the device has time to process before the next
      // write arrives. Without this, rapid-fire sends cause silent drops.
      await Future.delayed(_interWriteDelay);
    }

    _isPumping = false;
  }

  Future<void> _directWrite(String cmd) async {
    if (writeChar == null) return;
    try {
      await writeChar!.write(cmd.codeUnits, withoutResponse: true);
      if (kDebugMode) print('[BLE] TX: ${cmd.trim()}');
    } catch (e) {
      if (kDebugMode) print('[BLE] Write error: $e');
    }
  }

  // =========================================================================
  // Internal — keep-alive
  // =========================================================================

  void _startKeepAliveTimer() {
    _keepAliveTimer?.cancel();
    if (_keepAlivePaused) return;

    _keepAliveTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
      if (!_keepAlivePaused &&
          _writeQueue.isEmpty &&
          !_isPumping &&
          await isActuallyConnected) {
        if (kDebugMode) print('[BLE] Keep-alive');
        _enqueue(_QueuedCommand('#CMD idle 0\n', _Priority.normal));
      }
    });
  }

  // =========================================================================
  // Internal — BLE service discovery & notification subscription
  // =========================================================================

  Future<void> _discoverAndSubscribe() async {
    // Cancel any previous notify subscription before re-subscribing.
    // Without this, every reconnect adds another duplicate listener.
    await _notifySubscription?.cancel();
    _notifySubscription = null;

    final services = await device!.discoverServices();
    for (final s in services) {
      if (s.uuid == serviceUuid) {
        for (final c in s.characteristics) {
          if (c.uuid == writeUuid)  writeChar  = c;
          if (c.uuid == notifyUuid) notifyChar = c;
        }
      }
    }

    if (notifyChar != null && notifyChar!.properties.notify) {
      if (kDebugMode) print('[BLE] Subscribing to notifications');
      await notifyChar!.setNotifyValue(true);
      _notifySubscription = notifyChar!.onValueReceived.listen((bytes) {
        final msg = String.fromCharCodes(bytes);
        if (kDebugMode) print('[BLE] RX: ${msg.trim()}');
        onDataReceived?.call(msg);
      });
    }
  }

  // =========================================================================
  // Internal — connection state monitor & auto-reconnect
  // =========================================================================

  void _listenToConnectionState() {
    _connectionStateSubscription?.cancel();
    _connectionStateSubscription =
        device!.connectionState.listen((state) async {
          if (kDebugMode) print('[BLE] State: $state');

          if (state == BluetoothConnectionState.disconnected) {
            writeChar  = null;
            notifyChar = null;
            _writeQueue.clear();
            _isPumping = false;
            onConnectionStateChanged?.call(false);

            if (_userDisconnected || _isReconnecting) return;
            if (kDebugMode) print('[BLE] Dropped — auto-reconnecting…');
            await _autoReconnect();
          } else if (state == BluetoothConnectionState.connected) {
            onConnectionStateChanged?.call(true);
          }
        });
  }

  Future<void> _autoReconnect() async {
    if (_isReconnecting || device == null) return;
    _isReconnecting = true;

    const maxAttempts = 5;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      if (_userDisconnected) break;
      if (kDebugMode) print('[BLE] Reconnect $attempt/$maxAttempts…');
      try {
        await Future.delayed(Duration(seconds: attempt * 2));
        await device!.connect(autoConnect: false, mtu: 23);
        await _discoverAndSubscribe();
        if (kDebugMode) print('[BLE] Reconnected!');
        _isReconnecting = false;
        return;
      } catch (e) {
        if (kDebugMode) print('[BLE] Attempt $attempt failed: $e');
      }
    }

    if (kDebugMode) print('[BLE] All reconnect attempts failed');
    _isReconnecting = false;
    device = null;
  }

  // =========================================================================
  // Internal — Android permissions
  // =========================================================================

  Future<bool> _requestBlePermissions() async {
    if (!Platform.isAndroid) return true;

    final androidInfo = await DeviceInfoPlugin().androidInfo;
    final sdkInt = androidInfo.version.sdkInt;

    final permissions = <Permission>[];
    if (sdkInt >= 31) {
      permissions.addAll([Permission.bluetoothScan, Permission.bluetoothConnect]);
    } else {
      permissions.add(Permission.locationWhenInUse);
    }
    if (sdkInt >= 33) permissions.add(Permission.notification);

    final statuses = await permissions.request();

    final missing = statuses.entries.any((e) =>
    e.key != Permission.notification && !e.value.isGranted);

    if (missing) {
      if (kDebugMode) print('[BLE] Missing permissions: $statuses');
      await openAppSettings();
      return false;
    }
    return true;
  }
}