import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

class BluetoothHelper {
  final Guid serviceUuid = Guid('6e400001-b5a3-f393-e0a9-e50e24dcca9e');
  final Guid writeUuid = Guid('6e400002-b5a3-f393-e0a9-e50e24dcca9e');
  final Guid notifyUuid = Guid('6e400003-b5a3-f393-e0a9-e50e24dcca9e');

  BluetoothDevice? device;
  BluetoothCharacteristic? writeChar;
  BluetoothCharacteristic? notifyChar;

  Timer? _keepAliveTimer;

  // ✅ NEW: Connection state subscription — monitors drops and triggers reconnect
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;

  // ✅ NEW: Flag to prevent multiple simultaneous reconnect attempts
  bool _isReconnecting = false;

  // ✅ NEW: Flag to know if user intentionally disconnected (don't auto-reconnect)
  bool _userDisconnected = false;

  // Callback for incoming messages (used by main.dart)
  void Function(String msg)? onDataReceived;

  // ✅ NEW: Callback so main.dart knows when connection drops/restores
  void Function(bool connected)? onConnectionStateChanged;

  Future<bool> get isActuallyConnected async {
    if (device == null) return false;
    final state = await device!.connectionState.first;
    return state == BluetoothConnectionState.connected;
  }

  Queue<String> commandQueue = Queue<String>();
  bool isWriting = false;

  void enqueueCommand(String cmd) {
    commandQueue.add(cmd);
    if (kDebugMode) print("Command enqueued. Queue length: ${commandQueue.length}");
    _processQueue();
  }

  Future<void> _processQueue() async {
    if (isWriting || commandQueue.isEmpty || writeChar == null) return;
    if (await isActuallyConnected == false) return;

    isWriting = true;
    final nextCmd = commandQueue.removeFirst();
    try {
      final bytes = nextCmd.codeUnits;
      await writeChar!.write(bytes, withoutResponse: true);
      if (kDebugMode) print("Queued sent: $nextCmd");
    } catch (e) {
      if (kDebugMode) print("Error during queued write: $e");
      isWriting = false;
      _processQueue();
    }
  }

  void onOkFromDevice() {
    isWriting = false;
    _processQueue();
  }

  // ✅ FIXED: Keep-alive timer now enabled (was commented out before)
  void _startKeepAliveTimer() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 4), (timer) async {
      if (commandQueue.isEmpty && !isWriting && await isActuallyConnected) {
        if (kDebugMode) print("Sending keep-alive");
        enqueueCommand("#CMD idle 0\n");
      }
    });
  }

  void _stopKeepAliveTimer() {
    _keepAliveTimer?.cancel();
  }

  Future<void> sendCommand(String cmd) async {
    if (writeChar == null) return;
    try {
      final bytes = cmd.codeUnits;
      await writeChar!.write(bytes, withoutResponse: true);
      if (kDebugMode) print("Sent: $cmd");
    } catch (e) {
      if (kDebugMode) print("Write error: $e");
    }
  }

  Future<void> transferCommand(String cmd) async {
    enqueueCommand(cmd);
  }

  Future<void> flushAndSend(String stopCmd) async {
    if (kDebugMode) print("Flushing queue. Length: ${commandQueue.length}");
    commandQueue.clear();
    isWriting = false;
    try {
      final data = stopCmd.codeUnits;
      await writeChar!.write(data, withoutResponse: true);
      if (kDebugMode) print("Stopped");
    } catch (e) {
      if (kDebugMode) print("Error while stopping: $e");
    }
  }

  void emergencyStop(String stopCmd) {
    flushAndSend(stopCmd);
  }

  Future<void> disconnect() async {
    // ✅ Mark as intentional disconnect — prevents auto-reconnect
    _userDisconnected = true;
    _stopKeepAliveTimer();
    _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;

    if (device != null) {
      try {
        await device!.disconnect();
        if (kDebugMode) print("Disconnected from device");
      } catch (e) {
        if (kDebugMode) print("Error while disconnecting: $e");
      } finally {
        device = null;
        writeChar = null;
        notifyChar = null;
      }
    }
  }

  // ✅ NEW: Monitor connection state and auto-reconnect when dropped
  void _listenToConnectionState() {
    _connectionStateSubscription?.cancel();
    _connectionStateSubscription = device!.connectionState.listen((state) async {
      if (kDebugMode) print("BLE connection state: $state");

      if (state == BluetoothConnectionState.disconnected) {
        writeChar = null;
        notifyChar = null;
        onConnectionStateChanged?.call(false);

        // Don't reconnect if user intentionally disconnected
        if (_userDisconnected || _isReconnecting) return;

        if (kDebugMode) print("Connection dropped! Attempting auto-reconnect...");
        await _autoReconnect();
      } else if (state == BluetoothConnectionState.connected) {
        onConnectionStateChanged?.call(true);
      }
    });
  }

  // ✅ NEW: Auto-reconnect with retry logic
  Future<void> _autoReconnect() async {
    if (_isReconnecting || device == null) return;
    _isReconnecting = true;

    int attempts = 0;
    const maxAttempts = 5;

    while (attempts < maxAttempts && !_userDisconnected) {
      attempts++;
      if (kDebugMode) print("Reconnect attempt $attempts/$maxAttempts...");

      try {
        // Wait a bit before retrying
        await Future.delayed(Duration(seconds: attempts * 2));

        await device!.connect(autoConnect: false, mtu: 23);

        // Re-discover services after reconnect
        await _discoverAndSubscribe();

        if (kDebugMode) print("Reconnected successfully!");
        _isReconnecting = false;
        return;
      } catch (e) {
        if (kDebugMode) print("Reconnect attempt $attempts failed: $e");
      }
    }

    if (kDebugMode) print("All reconnect attempts failed.");
    _isReconnecting = false;
    device = null;
  }

  // ✅ NEW: Extracted service discovery into its own method (used by both connect and reconnect)
  Future<void> _discoverAndSubscribe() async {
    final services = await device!.discoverServices();
    for (final s in services) {
      if (s.uuid == serviceUuid) {
        for (final c in s.characteristics) {
          if (c.uuid == writeUuid) writeChar = c;
          if (c.uuid == notifyUuid) notifyChar = c;
        }
      }
    }

    if (notifyChar != null && notifyChar!.properties.notify) {
      if (kDebugMode) print("Subscribing to notifications...");
      await notifyChar!.setNotifyValue(true);
      notifyChar!.onValueReceived.listen((bytes) {
        final msg = String.fromCharCodes(bytes);
        if (kDebugMode) print("Device says: $msg");
        if (onDataReceived != null) {
          onDataReceived!(msg);
        }
      });
    }
  }

  Future<void> scanAndConnect() async {
    final Map<Permission, PermissionStatus> statuses =
    await [Permission.bluetoothScan, Permission.bluetoothConnect].request();

    if (statuses.values.any((s) => !s.isGranted)) {
      if (kDebugMode) print("Missing Bluetooth permissions");
      await openAppSettings();
      return;
    }

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 3));
    await FlutterBluePlus.isScanning.where((val) => val == false).first;

    ScanResult? target;
    try {
      target = FlutterBluePlus.lastScanResults.firstWhere(
            (r) => (r.device.platformName ?? '').contains('LMC#'),
      );
    } on StateError {
      target = null;
    }

    if (target == null) {
      if (kDebugMode) print("Device not found nearby.");
      return;
    }

    device = target.device;
    // ✅ Reset the intentional disconnect flag
    _userDisconnected = false;
    _isReconnecting = false;

    if (kDebugMode) print("Connecting to ${device!.platformName}...");

    try {
      // ✅ CHANGED: autoConnect: false for initial connect (faster),
      // auto-reconnect is handled by our own _autoReconnect() logic
      await device!.connect(autoConnect: false, mtu: 23);
    } catch (e) {
      if (kDebugMode) print("Connection failed: $e");
      return;
    }

    if (kDebugMode) print("Connected to ${device!.platformName}");

    // ✅ Start monitoring connection state BEFORE anything else
    _listenToConnectionState();

    // Discover services and subscribe to notifications
    await _discoverAndSubscribe();

    // ✅ Start keep-alive timer (was commented out before — this is critical!)
    _startKeepAliveTimer();
  }
}
