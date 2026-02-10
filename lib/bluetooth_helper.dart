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

  // Callback for incoming messages (used by main.dart)
  void Function(String msg)? onDataReceived;

  Future<bool> get isActuallyConnected async {
    if (device == null) return false;
    final state = await device!.connectionState.first;
    return state == BluetoothConnectionState.connected;
  }

  Queue<String> commandQueue = Queue<String>();
  bool isWriting = false;

  void enqueueCommand(String cmd) {
    commandQueue.add(cmd);
    if (kDebugMode) {
      print("Command enqueued. Queue length: ${commandQueue.length}");
    }
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
      // If you want to use #OK for flow control, call onOkFromDevice()
      // when you see "#OK" in notifications.
    } catch (e) {
      if (kDebugMode) print("Error during queued write: $e");
      isWriting = false;
      _processQueue(); // Try next command
    }
  }

  void onOkFromDevice() {
    isWriting = false;
    _processQueue();
  }

  void _startKeepAliveTimer() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer =
        Timer.periodic(const Duration(seconds: 4), (timer) async {
          if (commandQueue.isEmpty && !isWriting && await isActuallyConnected) {
            if (kDebugMode) print("Sending alive Command");
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
    if (kDebugMode) {
      print("Flushing queue. Length: ${commandQueue.length}");
    }
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
    //_stopKeepAliveTimer();
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
      if (kDebugMode) print("Umbrella not found nearby.");
      return;
    }

    device = target.device;
    if (kDebugMode) print("Connecting to ${device!.platformName}...");

    try {
      await device!.connect(autoConnect: false, mtu: 23);
    } catch (e) {
      if (kDebugMode) print("Connection failed: $e");
      return;
    }

    if (kDebugMode) print("Connected to ${device!.platformName}");

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
      if (kDebugMode) print("Listening for notifications...");
      await notifyChar!.setNotifyValue(true);
      notifyChar!.onValueReceived.listen((bytes) {
        final msg = String.fromCharCodes(bytes);
        if (kDebugMode) print("Device says: $msg");

        // Forward to app-level handler (main.dart)
        if (onDataReceived != null) {
          onDataReceived!(msg);
        }

        // If you later use the queue + #OK handshake:
        // if (msg.contains("#OK")) {
        //   onOkFromDevice();
        // }
      });
    }

    // Optionally start keep-alive
    //_startKeepAliveTimer();
  }
}
