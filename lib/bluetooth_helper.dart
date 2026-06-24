import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
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

  // Connection state subscription — monitors drops and triggers reconnect
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;

  // Flag to prevent multiple simultaneous reconnect attempts
  bool _isReconnecting = false;

  // Flag to know if user intentionally disconnected (don't auto-reconnect)
  bool _userDisconnected = false;

  // Callback for incoming messages (used by main.dart)
  void Function(String msg)? onDataReceived;

  // Callback so main.dart knows when connection drops/restores
  void Function(bool connected)? onConnectionStateChanged;

  Future<bool> get isActuallyConnected async {
    if (device == null) return false;
    final state = await device!.connectionState.first;
    return state == BluetoothConnectionState.connected;
  }

  String get connectedDeviceName => device?.platformName ?? "Unknown Device";

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

  void _listenToConnectionState() {
    _connectionStateSubscription?.cancel();
    _connectionStateSubscription = device!.connectionState.listen((state) async {
      if (kDebugMode) print("BLE connection state: $state");

      if (state == BluetoothConnectionState.disconnected) {
        writeChar = null;
        notifyChar = null;
        onConnectionStateChanged?.call(false);

        if (_userDisconnected || _isReconnecting) return;

        if (kDebugMode) print("Connection dropped! Attempting auto-reconnect...");
        await _autoReconnect();
      } else if (state == BluetoothConnectionState.connected) {
        onConnectionStateChanged?.call(true);
      }
    });
  }

  Future<void> _autoReconnect() async {
    if (_isReconnecting || device == null) return;
    _isReconnecting = true;

    int attempts = 0;
    const maxAttempts = 5;

    while (attempts < maxAttempts && !_userDisconnected) {
      attempts++;
      if (kDebugMode) print("Reconnect attempt $attempts/$maxAttempts...");

      try {
        await Future.delayed(Duration(seconds: attempts * 2));
        await device!.connect(autoConnect: false, mtu: 23);
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

  Future<bool> _requestBlePermissions() async {
    if (!Platform.isAndroid) return true;

    final androidInfo = await DeviceInfoPlugin().androidInfo;
    final sdkInt = androidInfo.version.sdkInt;

    final permissions = <Permission>[];

    if (sdkInt >= 31) {
      // Android 12 and above
      permissions.add(Permission.bluetoothScan);
      permissions.add(Permission.bluetoothConnect);
    } else {
      // Android 11 and below
      permissions.add(Permission.locationWhenInUse);
    }

    if (sdkInt >= 33) {
      // Android 13 and above
      permissions.add(Permission.notification);
    }

    final statuses = await permissions.request();

    final missingRequiredPermission = statuses.entries.any((entry) {
      // Notification permission should not block BLE scanning
      if (entry.key == Permission.notification) {
        return false;
      }

      return !entry.value.isGranted;
    });

    if (missingRequiredPermission) {
      if (kDebugMode) {
        print("Missing BLE permissions: $statuses");
      }
      await openAppSettings();
      return false;
    }

    return true;
  }

  Future<void> startScan() async {
    final permissionOk = await _requestBlePermissions();

    if (!permissionOk) {
      if (kDebugMode) print("BLE permissions not granted");
      return;
    }

    final adapterState = await FlutterBluePlus.adapterState.first;

    if (adapterState != BluetoothAdapterState.on) {
      if (kDebugMode) print("Bluetooth is not ON");
      return;
    }

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
  }

  Future<bool> connectToDevice(BluetoothDevice targetDevice) async {
    device = targetDevice;
    _userDisconnected = false;
    _isReconnecting = false;

    if (kDebugMode) print("Connecting to ${device!.platformName}...");

    try {
      await device!.connect(autoConnect: false, mtu: 23);
    } catch (e) {
      if (kDebugMode) print("Connection failed: $e");
      return false;
    }

    if (kDebugMode) print("Connected to ${device!.platformName}");
    _listenToConnectionState();
    await _discoverAndSubscribe();
    _startKeepAliveTimer();
    return true;
  }

  // Backward compatibility or quick search if needed
  Future<void> scanAndConnect() async {
    await startScan();
    await FlutterBluePlus.isScanning.where((val) => val == false).first;

    ScanResult? target;
    try {
      target = FlutterBluePlus.lastScanResults.firstWhere(
            (r) => (r.device.platformName ?? '').contains('LMC#'),
      );
    } on StateError {
      target = null;
    }

    if (target != null) {
      await connectToDevice(target.device);
    }
  }
}
