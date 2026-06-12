import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'bluetooth_helper.dart';
import 'command_helper.dart';
import 'device_selection_page.dart';
import 'test_session.dart';
import 'sessions_page.dart';

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(BleTaskHandler());
}

class BleTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'LMC Test App',
      theme: ThemeData(primarySwatch: Colors.orange),
      home: const MainPage(),
    );
  }
}

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> with WidgetsBindingObserver {
  final ble = BluetoothHelper();

  bool isConnected = false;
  bool _testRunning = false;
  bool _testPaused = false;
  bool _isPressed = false;

  // Test configuration (defaults)
  int _cycles = 3;
  int _moveUpSeconds = 40;
  int _moveDownSeconds = 40;
  int _waitUpSeconds = 5;
  int _waitDownSeconds = 5;

  final TextEditingController _cyclesController = TextEditingController(text: '3');
  final TextEditingController _moveUpController = TextEditingController(text: '40');
  final TextEditingController _moveDownController = TextEditingController(text: '40');
  final TextEditingController _waitUpController = TextEditingController(text: '5');
  final TextEditingController _waitDownController = TextEditingController(text: '5');

  int cyclesCompleted = 0;
  Timer? _idleTimer;
  int _currentCycleIndex = 0;
  String _currentPhase = 'idle';
  int _timeLeftSeconds = 0;

  DateTime? _testStartTime;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initForegroundTask();

    ble.onConnectionStateChanged = (bool connected) {
      if (!mounted) return;
      setState(() => isConnected = connected);
      if (!connected) {
        _stopIdleTimer();
        if (_testRunning && !_testPaused) {
          _testPaused = true;
          // Save progress when auto-paused by disconnection
          _saveSession();
          setState(() {});
        }
      } else {
        _startIdleTimer();
      }
    };
  }

  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'ble_channel',
        channelName: 'BLE Connection Service',
        channelDescription: 'Keeps BLE connection alive in background',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(5000),
        autoRunOnBoot: false,
        allowWakeLock: true,
      ),
    );
  }

  Future<void> _startForegroundTask() async {
    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      serviceId: 256,
      notificationTitle: 'LMC BLE Active',
      notificationText: 'Maintaining BLE connection...',
      callback: startCallback,
    );
  }

  Future<void> _stopForegroundTask() async {
    await FlutterForegroundTask.stopService();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cyclesController.dispose();
    _moveUpController.dispose();
    _moveDownController.dispose();
    _waitUpController.dispose();
    _waitDownController.dispose();
    _idleTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      ble.isActuallyConnected.then((connected) {
        if (mounted) setState(() => isConnected = connected);
        if (connected && _idleTimer == null) _startIdleTimer();
      });
    }
  }

  void _startIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer.periodic(const Duration(milliseconds: 380), (t) {
      if ((!_testRunning || _testPaused) && isConnected && !_isPressed) {
        ble.sendCommand(Commands.idle);
      }
    });
  }

  void _stopIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  void _setValues() {
    final cycles = int.tryParse(_cyclesController.text);
    final mUp = int.tryParse(_moveUpController.text);
    final mDown = int.tryParse(_moveDownController.text);
    final wUp = int.tryParse(_waitUpController.text);
    final wDown = int.tryParse(_waitDownController.text);
    if (cycles != null && cycles > 0) _cycles = cycles;
    if (mUp != null && mUp > 0) _moveUpSeconds = mUp;
    if (mDown != null && mDown > 0) _moveDownSeconds = mDown;
    if (wUp != null && wUp >= 0) _waitUpSeconds = wUp;
    if (wDown != null && wDown >= 0) _waitDownSeconds = wDown;
    setState(() {});
  }

  Future<void> _runMove({required bool goingUp}) async {
    final totalMs = (goingUp ? _moveUpSeconds : _moveDownSeconds) * 1000;
    _currentPhase = goingUp ? 'up' : 'down';
    setState(() {});
    final start = DateTime.now();
    DateTime lastSent = DateTime.fromMillisecondsSinceEpoch(0);
    const sendInterval = Duration(milliseconds: 700);
    while (_testRunning && !_testPaused) {
      final elapsedMs = DateTime.now().difference(start).inMilliseconds;
      if (elapsedMs >= totalMs) break;

      // Update countdown
      final remaining = ((totalMs - elapsedMs) / 1000).ceil();
      if (remaining != _timeLeftSeconds) {
        setState(() => _timeLeftSeconds = remaining);
      }

      if (DateTime.now().difference(lastSent) >= sendInterval) {
        await ble.sendCommand(goingUp ? Commands.up : Commands.down);
        lastSent = DateTime.now();
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
    await ble.sendCommand(Commands.idle);
  }

  Future<void> _runWait({required bool atTop}) async {
    final totalMs = (atTop ? _waitUpSeconds : _waitDownSeconds) * 1000;
    _currentPhase = atTop ? 'waitUp' : 'waitDown';
    setState(() {});
    await ble.sendCommand(Commands.idle);
    final start = DateTime.now();
    DateTime lastPing = DateTime.now().subtract(const Duration(seconds: 2));
    while (_testRunning && !_testPaused) {
      final elapsedMs = DateTime.now().difference(start).inMilliseconds;
      if (elapsedMs >= totalMs) break;

      // Update countdown
      final remaining = ((totalMs - elapsedMs) / 1000).ceil();
      if (remaining != _timeLeftSeconds) {
        setState(() => _timeLeftSeconds = remaining);
      }

      if (DateTime.now().difference(lastPing) >= const Duration(seconds: 2)) {
        await ble.sendCommand(Commands.idle);
        lastPing = DateTime.now();
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> _saveSession() async {
    if (_testStartTime == null) return;
    
    final session = TestSession(
      umbrellaName: ble.connectedDeviceName ?? "Unknown Umbrella",
      totalCycles: _cycles,
      completedCycles: cyclesCompleted,
      startTime: _testStartTime!,
      endTime: DateTime.now(),
    );
    
    await TestSession.saveOrUpdateSession(session);
  }

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
      cyclesCompleted = 0;
      _currentCycleIndex = 0;
      _currentPhase = 'up';
      _timeLeftSeconds = _moveUpSeconds;
      _testRunning = true;
      _testPaused = false;
      _testStartTime = DateTime.now();
      _stopIdleTimer();
      // Initial save to mark start
      await _saveSession();
      setState(() {});
    }

    while (_testRunning && _currentCycleIndex < _cycles) {
      if (_testPaused) { _startIdleTimer(); return; }
      if (_currentPhase == 'up') {
        await _runMove(goingUp: true);
        if (!_testRunning || _testPaused) break;
        _currentPhase = 'waitUp';
      }
      if (_currentPhase == 'waitUp') {
        await _runWait(atTop: true);
        if (!_testRunning || _testPaused) break;
        _currentPhase = 'down';
      }
      if (_currentPhase == 'down') {
        await _runMove(goingUp: false);
        if (!_testRunning || _testPaused) break;
        _currentPhase = 'waitDown';
      }
      if (_currentPhase == 'waitDown') {
        await _runWait(atTop: false);
        if (!_testRunning || _testPaused) break;
        _currentCycleIndex++;
        cyclesCompleted = _currentCycleIndex;
        
        // Auto-save after every completed cycle
        await _saveSession();
        
        _currentPhase = (_currentCycleIndex < _cycles) ? 'up' : 'idle';
        if (_currentPhase == 'idle') _timeLeftSeconds = 0;
        setState(() {});
      }
    }

    if (_testPaused) { _startIdleTimer(); return; }
    
    // Final update when test finishes naturally
    if (_testRunning) {
      await _saveSession();
    }

    _testRunning = false;
    _testPaused = false;
    _currentPhase = 'idle';
    _currentCycleIndex = 0;
    _timeLeftSeconds = 0;
    _testStartTime = null; 
    await ble.sendCommand(Commands.idle);
    _startIdleTimer();
    setState(() {});
  }

  Future<void> _pauseTest() async {
    if (!_testRunning || _testPaused) return;
    _testPaused = true;
    // Save progress immediately on pause
    await _saveSession();
    await ble.sendCommand(Commands.idle);
    _startIdleTimer();
    setState(() {});
  }

  Future<void> _stopTest() async {
    if (_testRunning) {
      await _saveSession();
    }
    _testRunning = false;
    _testPaused = false;
    _currentPhase = 'idle';
    _currentCycleIndex = 0;
    _timeLeftSeconds = 0;
    _testStartTime = null;
    await ble.sendCommand(Commands.idle);
    _startIdleTimer();
    setState(() {});
  }

  Future<void> _startContinuousCommand(String cmd) async {
    if (!isConnected || (_testRunning && !_testPaused)) return;
    _isPressed = true;
    _stopIdleTimer();
    while (_isPressed) {
      await ble.sendCommand(cmd);
      await Future.delayed(const Duration(milliseconds: 700));
    }
    await ble.sendCommand(Commands.idle);
    if (!_testRunning || _testPaused) _startIdleTimer();
  }

  void _stopContinuousCommand() {
    _isPressed = false;
    ble.emergencyStop(Commands.idle);
    Future.delayed(const Duration(milliseconds: 50), () {
      ble.sendCommand(Commands.idle);
      if (!_testRunning || _testPaused) _startIdleTimer();
    });
  }

  Future<void> scanAndConnect() async {
    if (isConnected) {
      await ble.disconnect();
      _stopIdleTimer();
      await _stopForegroundTask();
      setState(() => isConnected = false);
    } else {
      final result = await Navigator.of(context).push(
        MaterialPageRoute(builder: (context) => DeviceSelectionPage(ble: ble)),
      );
      if (result == true) {
        await _startForegroundTask();
        final newState = await ble.isActuallyConnected;
        setState(() => isConnected = newState);
        if (isConnected) _startIdleTimer();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Controls should be enabled if we are not running a test OR if the test is paused.
    bool controlsEnabled = !_testRunning || _testPaused;
    // Start/Resume button is only disabled when the test is running AND not paused.
    bool startEnabled = !_testRunning || _testPaused;
    // Disconnect button is enabled if test is not running OR if it's paused.
    bool disconnectEnabled = !_testRunning || _testPaused;

    return Scaffold(
      backgroundColor: Colors.grey[300],
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        toolbarHeight: 60,
        centerTitle: true,
        title: Image.asset('assets/ketterer_logo.png', height: 40, fit: BoxFit.contain),
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
                  Text('Hello', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
                  Text('Settings', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w500)),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.history, color: Colors.black54),
              title: const Text('Test History', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
              onTap: () {
                Navigator.pop(context); // Close drawer
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const SessionsPage()),
                );
              },
            ),
            const ListTile(
              leading: Icon(Icons.language, color: Colors.black54),
              title: Text('Language', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(5),
        child: Column(
          children: [
            Center(child: Text('LMC Test App', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey[600]))),
            const SizedBox(height: 2),
            Center(
              child: Text(
                isConnected ? 'Status: Connected (${ble.connectedDeviceName})' : 'Status: Disconnected',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: isConnected ? Colors.green : Colors.red),
              ),
            ),
            const SizedBox(height: 5),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 190,
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(15), boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 5, offset: Offset(0, 3))]),
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    children: [
                      const Center(child: Text('INPUTS', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey))),
                      const SizedBox(height: 8),
                      _inputRow('Cycles:', _cyclesController, null),
                      const SizedBox(height: 6),
                      _inputRow('Move up:', _moveUpController, 's'),
                      const SizedBox(height: 6),
                      _inputRow('Move down:', _moveDownController, 's'),
                      const SizedBox(height: 6),
                      _inputRow('Wait up:', _waitUpController, 's'),
                      const SizedBox(height: 6),
                      _inputRow('Wait down:', _waitDownController, 's'),
                    ],
                  ),
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 3))]),
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      children: [
                        const Text('RESULTS', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.grey)),
                        const SizedBox(height: 8),
                        const Text('CYCLES COMPLETED:', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFFE96A1E))),
                        const SizedBox(height: 4),
                        Text(cyclesCompleted.toString(), style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold, color: Colors.green)),
                        const SizedBox(height: 6),
                        Text('Phase: $_currentPhase', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text('Time left: ${_timeLeftSeconds}s', style: const TextStyle(fontSize: 12, color: Colors.blueGrey, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Row(
              children: [
                AbsorbPointer(
                  absorbing: !controlsEnabled,
                  child: Container(
                    height: 170,
                    width: 150,
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 3))]),
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 3),
                    child: Column(
                      children: [
                        const Text('CONTROLS', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.grey)),
                        const SizedBox(height: 5),
                        Listener(onPointerDown: (_) => _startContinuousCommand(Commands.up), onPointerUp: (_) => _stopContinuousCommand(), onPointerCancel: (_) => _stopContinuousCommand(), child: _controlButton('UP', Icons.arrow_upward, isEnabled: controlsEnabled)),
                        const SizedBox(height: 10),
                        Listener(onPointerDown: (_) => _startContinuousCommand(Commands.down), onPointerUp: (_) => _stopContinuousCommand(), onPointerCancel: (_) => _stopContinuousCommand(), child: _controlButton('DOWN', Icons.arrow_downward, isEnabled: controlsEnabled)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 15),
                Column(
                  children: [
                    ElevatedButton.icon(
                      onPressed: startEnabled ? _startTest : null, 
                      icon: Icon(_testPaused ? Icons.play_arrow : Icons.play_circle_fill), 
                      label: Text(_testPaused ? 'Resume Test' : 'Start Test', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)), 
                      style: ElevatedButton.styleFrom(
                        backgroundColor: startEnabled ? const Color(0xFFE96A1E) : Colors.grey, 
                        foregroundColor: Colors.white, 
                        minimumSize: const Size(10, 40), 
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))
                      )
                    ),
                    const SizedBox(height: 10),
                    ElevatedButton.icon(onPressed: (_testRunning && !_testPaused) ? _pauseTest : null, icon: const Icon(Icons.pause), label: const Text('Pause Test', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)), style: ElevatedButton.styleFrom(backgroundColor: (_testRunning && !_testPaused) ? Colors.amber : Colors.grey, foregroundColor: Colors.white, minimumSize: const Size(10, 40), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)))),
                    const SizedBox(height: 10),
                    ElevatedButton.icon(onPressed: _testRunning ? _stopTest : null, icon: const Icon(Icons.stop), label: const Text('Stop Test', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)), style: ElevatedButton.styleFrom(backgroundColor: _testRunning ? const Color(0xFFE96A1E) : Colors.grey, foregroundColor: Colors.white, minimumSize: const Size(10, 40), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)))),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: disconnectEnabled ? scanAndConnect : null, 
              icon: Icon(isConnected ? Icons.bluetooth_disabled : Icons.bluetooth), 
              label: Text(isConnected ? 'Disconnect' : 'Connect', style: const TextStyle(fontSize: 20)), 
              style: ElevatedButton.styleFrom(
                backgroundColor: disconnectEnabled ? const Color(0xFFE96A1E) : Colors.grey, 
                foregroundColor: Colors.white, 
                minimumSize: const Size(double.infinity, 55), 
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))
              )
            ),
          ],
        ),
      ),
    );
  }

  Widget _inputRow(String label, TextEditingController controller, String? suffix) {
    return Row(
      children: [
        SizedBox(width: 85, child: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold))),
        Expanded(child: SizedBox(height: 28, child: TextField(controller: controller, keyboardType: TextInputType.number, decoration: InputDecoration(suffixText: suffix, isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 6), border: const OutlineInputBorder())))),
      ],
    );
  }

  Widget _controlButton(String label, IconData icon, {bool isEnabled = true}) {
    return Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: isEnabled ? const Color(0xFFE96A1E) : Colors.grey, 
        borderRadius: BorderRadius.circular(6), 
        boxShadow: isEnabled ? const [BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 3))] : null
      ),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(icon, color: Colors.white), const SizedBox(width: 8), Text(label, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold))]),
    );
  }
}
