import 'dart:async';
import 'package:flutter/foundation.dart'; // Required for kDebugMode
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'bluetooth_helper.dart';
import 'command_helper.dart';

//  NEW: Top-level callback for flutter_foreground_task
// This runs in a separate isolate — keep it lightweight
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(BleTaskHandler());
}

//  NEW: Task handler — keeps the app process alive in background
class BleTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // Nothing needed here — just keeping process alive
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Called every interval — can be used for heartbeat logging if needed
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  final ble = BluetoothHelper();

  bool isConnected = false;

  // Test state flags
  bool _testRunning = false;
  bool _testPaused = false;

  // Manual press & hold
  bool _isPressed = false;

  // Height info from controller (mm)
  int currentHeight = 0;

  // MoveProgress (Register 12503) — "1" = moving, "0" = not moving
  int moveProgress = 0;
  DateTime _lastMoveProgressUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  // Height freshness
  DateTime _lastHeightUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  final Duration _waitKeepAliveInterval = const Duration(seconds: 2);

  // Test configuration (defaults)
  int _cycles = 3;
  int _waitUpSeconds = 10;
  int _waitDownSeconds = 10;

  // For UI text input
  final TextEditingController _cyclesController = TextEditingController(text: "3");
  final TextEditingController _waitUpController = TextEditingController(text: "10");
  final TextEditingController _waitDownController = TextEditingController(text: "10");

  // Result
  int cyclesCompleted = 0;

  // Keep-alive timer
  Timer? _idleTimer;

  // For resume logic
  int _currentCycleIndex = 0;
  String _currentPhase = "idle";
  double _phaseElapsedMs = 0;

  // Logs (optional)
  List<Map<String, dynamic>> currentLogs = [];
  int latest11011 = 0;

  // Safety timeout per direction
  final int _maxMoveMs = 60000;

  // Poll rates
  final Duration _progressPollInterval = const Duration(milliseconds: 120);
  final Duration _keepAliveMoveInterval = const Duration(milliseconds: 700);

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    //  NEW: Initialize the foreground task service
    _initForegroundTask();

    //  Listen to connection drops/restores from bluetooth_helper
    ble.onConnectionStateChanged = (bool connected) {
      if (!mounted) return;
      setState(() => isConnected = connected);

      if (!connected) {
        //  Connection dropped — stop everything cleanly
        _stopIdleTimer();

        // If a test was running, pause it so it can resume after reconnect
        if (_testRunning && !_testPaused) {
          _testPaused = true;
          setState(() => _currentPhase = "idle");
        }

        if (kDebugMode) print("UI: Connection lost — status updated to Disconnected");
      } else {
        //  Reconnected — restart idle timer and resume state
        _startIdleTimer();
        if (kDebugMode) print("UI: Reconnected — status updated to Connected");
      }
    };

    ble.onDataReceived = (String msg) {
      msg = msg.trim();

      if (msg.startsWith("#R12503=")) {
        final val = int.tryParse(msg.split("=").last);
        if (val != null) {
          moveProgress = val;
          _lastMoveProgressUpdate = DateTime.now();
          if (mounted) setState(() {});
        }
      }
    };
  }

  //  NEW: Setup flutter_foreground_task
  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'ble_channel',
        channelName: 'BLE Connection Service',
        channelDescription: 'Keeps BLE connection alive in background',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(5000), // heartbeat every 5s
        autoRunOnBoot: false,
        allowWakeLock: true, //  Prevents CPU from sleeping — critical for BLE
        allowWifiLock: false,
      ),
    );
  }

  //  NEW: Start the foreground task (shows persistent notification, keeps process alive)
  Future<void> _startForegroundTask() async {
    if (await FlutterForegroundTask.isRunningService) return;

    await FlutterForegroundTask.startService(
      serviceId: 256,
      notificationTitle: 'LMC BLE Active',
      notificationText: 'Maintaining BLE connection...',
      callback: startCallback,
    );
  }

  //  NEW: Stop the foreground task when disconnected
  Future<void> _stopForegroundTask() async {
    await FlutterForegroundTask.stopService();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cyclesController.dispose();
    _waitUpController.dispose();
    _waitDownController.dispose();
    _idleTimer?.cancel();
    super.dispose();
  }

  //  NEW: Handle app going to background / coming to foreground
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.paused) {
      // App going to background — foreground service keeps process alive
      if (kDebugMode) print("App backgrounded — foreground service keeping BLE alive");
    } else if (state == AppLifecycleState.resumed) {
      // App came back to foreground — re-sync connection state
      if (kDebugMode) print("App foregrounded — re-checking BLE state");
      ble.isActuallyConnected.then((connected) {
        if (mounted) setState(() => isConnected = connected);
        if (connected && _idleTimer == null) {
          _startIdleTimer();
        }
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Keep-alive idle timer
  // ---------------------------------------------------------------------------

  void _startIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer.periodic(const Duration(milliseconds: 380), (Timer t) {
      if ((!_testRunning || _testPaused) && isConnected && !_isPressed) {
        ble.sendCommand("#GR=10000\n");
      }
    });
  }

  void _stopIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  // ---------------------------------------------------------------------------
  // Poll MoveProgress (Register 12503)
  // ---------------------------------------------------------------------------

  Future<int?> _pollMoveProgress() async {
    if (!isConnected) return null;

    final beforeStamp = _lastMoveProgressUpdate;

    await ble.sendCommand("#GR=12503\n");
    await Future.delayed(const Duration(milliseconds: 80));

    if (_lastMoveProgressUpdate != beforeStamp) return moveProgress;

    await Future.delayed(const Duration(milliseconds: 80));
    if (_lastMoveProgressUpdate != beforeStamp) return moveProgress;

    return null;
  }

  // ---------------------------------------------------------------------------
  // UI inputs
  // ---------------------------------------------------------------------------

  void _setValues() {
    final cycles = int.tryParse(_cyclesController.text);
    final wUp = int.tryParse(_waitUpController.text);
    final wDown = int.tryParse(_waitDownController.text);

    if (cycles != null && cycles > 0) _cycles = cycles;
    if (wUp != null && wUp >= 0) _waitUpSeconds = wUp;
    if (wDown != null && wDown >= 0) _waitDownSeconds = wDown;

    setState(() {});
  }

  // ---------------------------------------------------------------------------
  // Move with 6-second mandatory minimum, then stop when moveProgress = 0
  // ---------------------------------------------------------------------------

  Future<void> _moveUntilControllerStops({required bool goingUp}) async {
    if (!isConnected) return;

    _currentPhase = goingUp ? "up" : "down";
    setState(() {});

    final start = DateTime.now();
    DateTime lastKeepAlive = DateTime.fromMillisecondsSinceEpoch(0);
    const mandatoryMoveMs = 8000; // Motor runs AT LEAST 8 seconds no matter what


    while (_testRunning && !_testPaused) {
      final elapsed = DateTime.now().difference(start).inMilliseconds;

      // Safety timeout
      if (elapsed > _maxMoveMs) {
        if (kDebugMode) print("Safety timeout — stopping");
        break;
      }

      // Send keep-alive move command periodically
      if (DateTime.now().difference(lastKeepAlive) >= _keepAliveMoveInterval) {
        await ble.sendCommand(goingUp ? Commands.up : Commands.down);
        lastKeepAlive = DateTime.now();
      }

      // Only check moveProgress AFTER mandatory 6 seconds have passed
      if (elapsed >= mandatoryMoveMs) {
        final p = await _pollMoveProgress();
        if (p != null && p == 0) {
          break;
        }
      }

      await Future.delayed(_progressPollInterval);
    }

    await ble.sendCommand(Commands.idle);
  }

  // ---------------------------------------------------------------------------
  // Wait at end
  // ---------------------------------------------------------------------------

  Future<void> _waitAtEnd({required bool atTop}) async {
    final totalMs = (atTop ? _waitUpSeconds : _waitDownSeconds) * 1000;
    final waitPhase = atTop ? "waitUp" : "waitDown";

    if (_currentPhase != waitPhase) {
      _currentPhase = waitPhase;
      setState(() {});
    }

    await ble.sendCommand(Commands.idle);

    final start = DateTime.now();
    DateTime lastPing = DateTime.now().subtract(_waitKeepAliveInterval);

    while (_testRunning && !_testPaused) {
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      _phaseElapsedMs = elapsed.toDouble();

      if (elapsed >= totalMs) break;

      if (DateTime.now().difference(lastPing) >= _waitKeepAliveInterval) {
        await ble.sendCommand("#GR=12503\n");
        lastPing = DateTime.now();
      }

      await Future.delayed(const Duration(milliseconds: 100));
    }

    if (_testPaused) return;
    _phaseElapsedMs = 0;
  }

  // ---------------------------------------------------------------------------
  // Start / Resume test
  // ---------------------------------------------------------------------------

  Future<void> _startTest() async {
    if (!isConnected) return;

    if (_testRunning && _testPaused) {
      _testPaused = false;
      _stopIdleTimer();
      setState(() {});
    } else if (_testRunning && !_testPaused) {
      return;
    } else {
      _setValues();
      currentLogs.clear();

      cyclesCompleted = 0;
      _currentCycleIndex = 0;
      _currentPhase = "up";
      _phaseElapsedMs = 0;

      _testRunning = true;
      _testPaused = false;
      _stopIdleTimer();
      setState(() {});
    }

    while (_testRunning && _currentCycleIndex < _cycles) {
      if (_testPaused) {
        _startIdleTimer();
        return;
      }

      if (_currentPhase == "up") {
        await _moveUntilControllerStops(goingUp: true);
        if (!_testRunning || _testPaused) break;
        _currentPhase = "waitUp";
        _phaseElapsedMs = 0;
        setState(() {});
      }

      if (_currentPhase == "waitUp") {
        await _waitAtEnd(atTop: true);
        if (!_testRunning || _testPaused) break;
        _currentPhase = "down";
        _phaseElapsedMs = 0;
        setState(() {});
      }

      if (_currentPhase == "down") {
        await _moveUntilControllerStops(goingUp: false);
        if (!_testRunning || _testPaused) break;
        _currentPhase = "waitDown";
        _phaseElapsedMs = 0;
        setState(() {});
      }

      if (_currentPhase == "waitDown") {
        await _waitAtEnd(atTop: false);
        if (!_testRunning || _testPaused) break;

        _currentCycleIndex++;
        cyclesCompleted = _currentCycleIndex;
        setState(() {});

        _currentPhase = (_currentCycleIndex < _cycles) ? "up" : "idle";
        _phaseElapsedMs = 0;
        setState(() {});
      }
    }

    if (_testPaused) {
      _startIdleTimer();
      return;
    }

    _testRunning = false;
    _testPaused = false;
    _currentPhase = "idle";
    _currentCycleIndex = 0;
    _phaseElapsedMs = 0;

    await ble.sendCommand(Commands.idle);
    _startIdleTimer();
    setState(() {});
  }

  Future<void> _pauseTest() async {
    if (!_testRunning || _testPaused) return;
    _testPaused = true;
    await ble.sendCommand(Commands.idle);
    _startIdleTimer();
    setState(() {});
  }

  Future<void> _stopTest() async {
    _testRunning = false;
    _testPaused = false;
    _currentPhase = "idle";
    _currentCycleIndex = 0;
    _phaseElapsedMs = 0;

    await ble.sendCommand(Commands.idle);
    _startIdleTimer();
    setState(() {});
  }

  // ---------------------------------------------------------------------------
  // Manual Commands (press & hold)
  // ---------------------------------------------------------------------------

  Future<void> _startContinuousCommand(String cmd) async {
    if (!isConnected) return;
    _isPressed = true;
    _stopIdleTimer();

    while (_isPressed) {
      await ble.sendCommand(cmd);
      await Future.delayed(const Duration(milliseconds: 980));
    }

    await ble.sendCommand(Commands.idle);
    if (!_testRunning) _startIdleTimer();
  }

  void _stopContinuousCommand() {
    _isPressed = false;
    ble.emergencyStop(Commands.idle);
    Future.delayed(const Duration(milliseconds: 50), () {
      ble.sendCommand(Commands.idle);
      if (!_testRunning) _startIdleTimer();
    });
  }

  // ---------------------------------------------------------------------------
  // Scan & Connect
  // ---------------------------------------------------------------------------

  Future<void> scanAndConnect() async {
    if (isConnected) {
      await ble.disconnect();
      _stopIdleTimer();
      //  Stop foreground task when user disconnects
      await _stopForegroundTask();
    } else {
      //  Start foreground task BEFORE connecting — keeps process alive
      await _startForegroundTask();
      await ble.scanAndConnect();
    }

    final newState = await ble.isActuallyConnected;
    setState(() => isConnected = newState);

    if (isConnected) {
      _startIdleTimer();
      await ble.sendCommand("#GR=10000\n");
      await ble.sendCommand("#GR=12503\n");
    } else {
      // If connection failed, stop the foreground task
      await _stopForegroundTask();
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Builder(
        builder: (context) {
          return Scaffold(
            backgroundColor: Colors.grey[300],
            appBar: AppBar(
              backgroundColor: Colors.white,
              elevation: 0,
              toolbarHeight: 60,
              centerTitle: true,
              title: Center(
                child: Image.asset(
                  'assets/ketterer_logo.png',
                  height: 40,
                  fit: BoxFit.contain,
                ),
              ),
            ),
            drawer: Drawer(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  DrawerHeader(
                    decoration: const BoxDecoration(color: Color(0xFFE96A1E)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: const [
                        Text('Hello, Rahul',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 24,
                                fontWeight: FontWeight.bold)),
                        Text('Settings',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ),
                  const ListTile(
                    leading: Icon(Icons.language, color: Colors.black54),
                    title: Text('Language',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                  ),
                  const ListTile(
                    leading: Icon(Icons.dark_mode, color: Colors.black54),
                    title: Text('Dark mode',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                  ),
                  const ListTile(
                    leading: Icon(Icons.logout, color: Colors.black54),
                    title: Text('Logout',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                  ),
                  const ListTile(
                    leading: Icon(Icons.info_outline, color: Colors.black54),
                    title: Text('About',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                  ),
                  ListTile(
                    leading: const Icon(Icons.list, color: Colors.black54),
                    title: const Text('Logs',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
            body: Padding(
              padding: const EdgeInsets.all(5),
              child: Column(
                children: [
                  Center(
                    child: Text("LMC Test App",
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.grey[600])),
                  ),
                  const SizedBox(height: 2),
                  Center(
                    child: Text(
                      "Status: ${isConnected ? "Connected" : "Disconnected"}",
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: isConnected ? Colors.green : Colors.red),
                    ),
                  ),
                  const SizedBox(height: 5),

                  // INPUTS + RESULTS
                  Row(
                    children: [
                      Container(
                        height: 210,
                        width: 180,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(15),
                          boxShadow: const [
                            BoxShadow(
                                color: Colors.black26,
                                blurRadius: 5,
                                offset: Offset(0, 3))
                          ],
                        ),
                        padding: const EdgeInsets.all(3),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Center(
                              child: Text("INPUTS",
                                  style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.grey)),
                            ),
                            const SizedBox(height: 6),
                            Text("MoveProgress: $moveProgress",
                                style: const TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                const Text("Cycles:",
                                    style: TextStyle(
                                        fontSize: 13, fontWeight: FontWeight.bold)),
                                const SizedBox(width: 3),
                                SizedBox(
                                  width: 70,
                                  height: 28,
                                  child: TextField(
                                    controller: _cyclesController,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                        isDense: true,
                                        contentPadding:
                                        EdgeInsets.symmetric(horizontal: 6),
                                        border: OutlineInputBorder()),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                const Text("Wait up:",
                                    style: TextStyle(
                                        fontSize: 13, fontWeight: FontWeight.bold)),
                                const SizedBox(width: 3),
                                SizedBox(
                                  width: 90,
                                  height: 28,
                                  child: TextField(
                                    controller: _waitUpController,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                        suffixText: "s",
                                        isDense: true,
                                        contentPadding:
                                        EdgeInsets.symmetric(horizontal: 6),
                                        border: OutlineInputBorder()),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                const Text("Wait down:",
                                    style: TextStyle(
                                        fontSize: 13, fontWeight: FontWeight.bold)),
                                const SizedBox(width: 3),
                                SizedBox(
                                  width: 90,
                                  height: 28,
                                  child: TextField(
                                    controller: _waitDownController,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                        suffixText: "s",
                                        isDense: true,
                                        contentPadding:
                                        EdgeInsets.symmetric(horizontal: 6),
                                        border: OutlineInputBorder()),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(width: 5),

                      Container(
                        height: 210,
                        width: 160,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: const [
                            BoxShadow(
                                color: Colors.black26,
                                blurRadius: 8,
                                offset: Offset(0, 3))
                          ],
                        ),
                        padding: const EdgeInsets.all(5),
                        child: Column(
                          children: [
                            const Text("RESULTS",
                                style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.grey)),
                            const SizedBox(height: 10),
                            const Text("CYCLES COMPLETED:",
                                style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFFE96A1E))),
                            const SizedBox(height: 5),
                            Text(cyclesCompleted.toString(),
                                style: const TextStyle(
                                    fontSize: 30,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.green)),
                            const SizedBox(height: 8),
                            Text("Phase: $_currentPhase",
                                style: const TextStyle(
                                    fontSize: 12, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 5),

                  // CONTROLS + TEST BUTTONS
                  Row(
                    children: [
                      Container(
                        height: 170,
                        width: 150,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: const [
                            BoxShadow(
                                color: Colors.black26,
                                blurRadius: 8,
                                offset: Offset(0, 3))
                          ],
                        ),
                        padding: const EdgeInsets.symmetric(
                            vertical: 8, horizontal: 3),
                        child: Column(
                          children: [
                            const Text("CONTROLS",
                                style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.grey)),
                            const SizedBox(height: 5),
                            Listener(
                              onPointerDown: (_) =>
                                  _startContinuousCommand(Commands.up),
                              onPointerUp: (_) => _stopContinuousCommand(),
                              onPointerCancel: (_) => _stopContinuousCommand(),
                              child: Container(
                                alignment: Alignment.center,
                                padding:
                                const EdgeInsets.symmetric(vertical: 14),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFE96A1E),
                                  borderRadius: BorderRadius.circular(6),
                                  boxShadow: const [
                                    BoxShadow(
                                        color: Colors.black26,
                                        blurRadius: 8,
                                        offset: Offset(0, 3))
                                  ],
                                ),
                                child: const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.arrow_upward, color: Colors.white),
                                    SizedBox(width: 10),
                                    Text("UP",
                                        style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 18,
                                            fontWeight: FontWeight.bold)),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Listener(
                              onPointerDown: (_) =>
                                  _startContinuousCommand(Commands.down),
                              onPointerUp: (_) => _stopContinuousCommand(),
                              onPointerCancel: (_) => _stopContinuousCommand(),
                              child: Container(
                                alignment: Alignment.center,
                                padding:
                                const EdgeInsets.symmetric(vertical: 14),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFE96A1E),
                                  borderRadius: BorderRadius.circular(6),
                                  boxShadow: const [
                                    BoxShadow(
                                        color: Colors.black26,
                                        blurRadius: 8,
                                        offset: Offset(0, 3))
                                  ],
                                ),
                                child: const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.arrow_downward,
                                        color: Colors.white),
                                    SizedBox(width: 8),
                                    Text("DOWN",
                                        style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 18,
                                            fontWeight: FontWeight.bold)),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(width: 15),

                      Column(
                        children: [
                          ElevatedButton.icon(
                            onPressed: _startTest,
                            icon: Icon(_testPaused
                                ? Icons.play_arrow
                                : Icons.play_circle_fill),
                            label: Text(
                              _testPaused ? "Resume Test" : "Start Test",
                              style: const TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.bold),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFE96A1E),
                              foregroundColor: Colors.white,
                              minimumSize: const Size(10, 40),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8)),
                            ),
                          ),
                          const SizedBox(height: 10),
                          ElevatedButton.icon(
                            onPressed: _pauseTest,
                            icon: const Icon(Icons.pause),
                            label: const Text("Pause Test",
                                style: TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.bold)),
                            style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.amber,
                                foregroundColor: Colors.white,
                                minimumSize: const Size(10, 40),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8))),
                          ),
                          const SizedBox(height: 10),
                          ElevatedButton.icon(
                            onPressed: _stopTest,
                            icon: const Icon(Icons.stop),
                            label: const Text("Stop Test",
                                style: TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.bold)),
                            style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFE96A1E),
                                foregroundColor: Colors.white,
                                minimumSize: const Size(10, 40),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8))),
                          ),
                        ],
                      ),
                    ],
                  ),

                  const SizedBox(height: 20),

                  ElevatedButton.icon(
                    onPressed: scanAndConnect,
                    icon: Icon(isConnected
                        ? Icons.bluetooth_disabled
                        : Icons.bluetooth),
                    label: Text(isConnected ? "Disconnect" : "Connect",
                        style: const TextStyle(fontSize: 20)),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFE96A1E),
                        foregroundColor: Colors.white,
                        minimumSize: const Size(double.infinity, 55),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8))),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
