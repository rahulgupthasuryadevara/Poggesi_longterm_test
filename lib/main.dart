import 'dart:async';
import 'package:flutter/material.dart';
import 'bluetooth_helper.dart';
import 'command_helper.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final ble = BluetoothHelper();

  bool isConnected = false;

  // Test state flags
  bool _testRunning = false;
  bool _testPaused = false;

  // Manual press & hold
  bool _isPressed = false;

  // Height info from controller (mm)
  int currentHeight = 0; // #R10000=

  // -----------------------------
  // NEW: MoveProgress (Register 12503)
  // "1" = moving, "0" = not moving
  // -----------------------------
  int moveProgress = 0; // #R12503=
  DateTime _lastMoveProgressUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  // Height freshness
  DateTime _lastHeightUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  final Duration _waitKeepAliveInterval = const Duration(seconds: 2);

  // Test configuration (defaults)
  int _cycles = 3;
  int _waitUpSeconds = 10;
  int _waitDownSeconds = 10;

  // For UI text input
  final TextEditingController _cyclesController =
  TextEditingController(text: "3");
  final TextEditingController _waitUpController =
  TextEditingController(text: "10");
  final TextEditingController _waitDownController =
  TextEditingController(text: "10");

  // Result
  int cyclesCompleted = 0;

  // Keep-alive timer
  Timer? _idleTimer;

  // For resume logic
  int _currentCycleIndex = 0; // 0-based index of cycle we are in
  String _currentPhase = "idle"; // "up", "waitUp", "down", "waitDown", "idle"
  double _phaseElapsedMs = 0; // used only for wait phases

  // Logs (optional)
  List<Map<String, dynamic>> currentLogs = [];
  int latest11011 = 0;

  // Safety timeout per direction
  final int _maxMoveMs = 60000;

  // Poll rates (tune if needed)
  final Duration _progressPollInterval = const Duration(milliseconds: 120);
  final Duration _keepAliveMoveInterval = const Duration(milliseconds: 700);

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();

    ble.onDataReceived = (String msg) {
      msg = msg.trim();

      if (msg.startsWith("#R12503=")) {
        final val = int.tryParse(msg.split("=").last);
        if (val != null) {
          moveProgress = val;
          _lastMoveProgressUpdate = DateTime.now();
          setState(() {});
        }
      }

      // If later you enable R11011:
      // else if (msg.startsWith("#R11011=")) { ... }
    };
  }

  @override
  void dispose() {
    _cyclesController.dispose();
    _waitUpController.dispose();
    _waitDownController.dispose();
    _idleTimer?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Keep-alive
  // ---------------------------------------------------------------------------

  void _startIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer.periodic(const Duration(milliseconds: 380), (Timer t) {
      // Send idle also when PAUSED
      if ((!_testRunning || _testPaused) && isConnected && !_isPressed) {
        // If your controller needs periodic idle, uncomment:
        ble.sendCommand("#GR=12503\n");
      }
    });
  }

  void _stopIdleTimer() {
    _idleTimer?.cancel();
  }

  // ---------------------------------------------------------------------------
  // Poll height (for UI freshness / optional)
  // ---------------------------------------------------------------------------

  /*Future<int?> _pollHeight() async {
    if (!isConnected) return null;

    final beforeStamp = _lastHeightUpdate;

    await ble.sendCommand("#GR=10000\n");
    await Future.delayed(const Duration(milliseconds: 80));

    if (_lastHeightUpdate != beforeStamp) return currentHeight;

    await Future.delayed(const Duration(milliseconds: 80));
    if (_lastHeightUpdate != beforeStamp) return currentHeight;
    return null;
  }*/

  // ---------------------------------------------------------------------------
  // Poll MoveProgress (Register 12503)
  // returns 0/1 when fresh, null if no fresh update
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
  // MOVE USING MoveProgress (12503)
  // Logic:
  //  - start moving (send UP/DOWN)
  //  - poll 12503; while it is "1" keep waiting
  //  - as soon as it becomes "0" => motor stopped => go idle + return
  // Notes:
  //  - we also "refresh" move command every _keepAliveMoveInterval in case
  //    your controller requires periodic commands to keep moving.
  // ---------------------------------------------------------------------------

  Future<void> _moveUntilControllerStops({required bool goingUp}) async {
    if (!isConnected) return;

    _currentPhase = goingUp ? "up" : "down";
    setState(() {});

    final start = DateTime.now();
    DateTime lastKeepAlive = DateTime.fromMillisecondsSinceEpoch(0);

    // Kick movement once
    await ble.sendCommand(goingUp ? Commands.up : Commands.down);

    // Optional: prime a progress read so we have a baseline
    await _pollMoveProgress();

    while (_testRunning && !_testPaused) {
      final elapsed = DateTime.now().difference(start).inMilliseconds;

      // safety timeout
      if (elapsed > _maxMoveMs) {
        break;
      }

      // keep-alive move command (only if needed)
      if (DateTime.now().difference(lastKeepAlive) >= _keepAliveMoveInterval) {
        await ble.sendCommand(goingUp ? Commands.up : Commands.down);
        lastKeepAlive = DateTime.now();
      }

      // poll move progress
      final p = await _pollMoveProgress();
      if (p != null && p == 0) {
        // controller says motor is not moving => reached end/stop
        break;
      }

      // optional: poll height occasionally so UI updates while moving
      // (you can remove this if you don't want extra traffic)
      //await _pollHeight();

      await Future.delayed(_progressPollInterval);
    }

    await ble.sendCommand(Commands.idle);
  }

  // ---------------------------------------------------------------------------
  // Wait at end (precise)
  // ---------------------------------------------------------------------------

  Future<void> _waitAtEnd({required bool atTop}) async {
    final totalMs = (atTop ? _waitUpSeconds : _waitDownSeconds) * 1000;
    final waitPhase = atTop ? "waitUp" : "waitDown";

    if (_currentPhase != waitPhase) {
      _currentPhase = waitPhase;
      setState(() {});
    }

    // Send idle once when entering wait
    await ble.sendCommand(Commands.idle);

    final start = DateTime.now();
    DateTime lastPing = DateTime.now().subtract(_waitKeepAliveInterval);

    while (_testRunning && !_testPaused) {
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      _phaseElapsedMs = elapsed.toDouble();

      if (elapsed >= totalMs) break;

      // ✅ Keep-alive: force BLE traffic + response
      if (DateTime.now().difference(lastPing) >= _waitKeepAliveInterval) {
        await ble.sendCommand("#GR=12503\n"); // safe read (response expected)
        // If your controller requires, you can also send idle:
        // await ble.sendCommand(Commands.idle);
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

    // Resume
    if (_testRunning && _testPaused) {
      _testPaused = false;
      _stopIdleTimer();
      setState(() {});
    }
    // Already running
    else if (_testRunning && !_testPaused) {
      return;
    }
    // New test
    else {
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

    // MAIN LOOP
    while (_testRunning && _currentCycleIndex < _cycles) {
      if (_testPaused) {
        _startIdleTimer();
        return;
      }

      // ------------------- UP UNTIL CONTROLLER STOPS -------------------
      if (_currentPhase == "up") {
        await _moveUntilControllerStops(goingUp: true);
        if (!_testRunning || _testPaused) break;

        _currentPhase = "waitUp";
        _phaseElapsedMs = 0;
        setState(() {});
      }

      // ------------------- WAIT AT TOP -------------------
      if (_currentPhase == "waitUp") {
        await _waitAtEnd(atTop: true);
        if (!_testRunning || _testPaused) break;

        _currentPhase = "down";
        _phaseElapsedMs = 0;
        setState(() {});
      }

      // ------------------- DOWN UNTIL CONTROLLER STOPS -------------------
      if (_currentPhase == "down") {
        await _moveUntilControllerStops(goingUp: false);
        if (!_testRunning || _testPaused) break;

        _currentPhase = "waitDown";
        _phaseElapsedMs = 0;
        setState(() {});
      }

      // ------------------- WAIT AT BOTTOM -------------------
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

    // Finished
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
    } else {
      await ble.scanAndConnect();
    }

    final newState = await ble.isActuallyConnected;
    setState(() => isConnected = newState);

    if (isConnected) {
      _startIdleTimer();
      // get one height read + one move progress read
      await ble.sendCommand("#GR=10000\n");
      await ble.sendCommand("#GR=12503\n");
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final textStyleLabel =
    const TextStyle(fontSize: 17, fontWeight: FontWeight.bold);

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
                    decoration:
                    const BoxDecoration(color: Color(0xFFE96A1E)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: const [
                        Text(
                          'Hello, Rahul',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.bold),
                        ),
                        Text(
                          'Settings',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                  ),
                  const ListTile(
                    leading: Icon(Icons.language, color: Colors.black54),
                    title: Text('Language',
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w600)),
                  ),
                  const ListTile(
                    leading: Icon(Icons.dark_mode, color: Colors.black54),
                    title: Text('Dark mode',
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w600)),
                  ),
                  const ListTile(
                    leading: Icon(Icons.logout, color: Colors.black54),
                    title: Text('Logout',
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w600)),
                  ),
                  const ListTile(
                    leading: Icon(Icons.info_outline, color: Colors.black54),
                    title: Text('About',
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w600)),
                  ),
                  ListTile(
                    leading: const Icon(Icons.list, color: Colors.black54),
                    title: const Text(
                      'Logs',
                      style:
                      TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                    ),
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
                      // INPUTS CONTAINER
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
                            Text(
                              "MoveProgress: $moveProgress",
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                const Text("Cycles:",
                                    style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold)),
                                const SizedBox(width: 3),
                                SizedBox(
                                  width: 70,
                                  height: 28,
                                  child: TextField(
                                    controller: _cyclesController,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                        isDense: true,
                                        contentPadding: EdgeInsets.symmetric(
                                            horizontal: 6),
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
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold)),
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
                                        contentPadding: EdgeInsets.symmetric(
                                            horizontal: 6),
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
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold)),
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
                                        contentPadding: EdgeInsets.symmetric(
                                            horizontal: 6),
                                        border: OutlineInputBorder()),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(width: 5),

                      // RESULTS CONTAINER
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
                            Text(
                              cyclesCompleted.toString(),
                              style: const TextStyle(
                                  fontSize: 30,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.green),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              "Phase: $_currentPhase",
                              style: const TextStyle(
                                  fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 5),

                  // CONTROLS + TEST BUTTONS
                  Row(
                    children: [
                      // MANUAL CONTROLS
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

                            // UP Button
                            GestureDetector(
                              onTapDown: (_) =>
                                  _startContinuousCommand(Commands.up),
                              onTapUp: (_) => _stopContinuousCommand(),
                              onTapCancel: _stopContinuousCommand,
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
                                    Icon(Icons.arrow_upward,
                                        color: Colors.white),
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

                            // DOWN Button
                            GestureDetector(
                              onTapDown: (_) =>
                                  _startContinuousCommand(Commands.down),
                              onTapUp: (_) => _stopContinuousCommand(),
                              onTapCancel: _stopContinuousCommand,
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

                      // TEST BUTTONS
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
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFE96A1E),
                              foregroundColor: Colors.white,
                              minimumSize: const Size(10, 40),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          ElevatedButton.icon(
                            onPressed: _pauseTest,
                            icon: const Icon(Icons.pause),
                            label: const Text("Pause Test",
                                style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold)),
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
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold)),
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

                  // CONNECT BUTTON
                  ElevatedButton.icon(
                    onPressed: scanAndConnect,
                    icon: Icon(
                        isConnected ? Icons.bluetooth_disabled : Icons.bluetooth),
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
