import 'dart:async';
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

  int? minHeight;
  int? maxHeight;
  int? currentHeight;

  int _cycles = 3;
  int _waitUpSeconds = 5;
  int _waitDownSeconds = 5;
  int _waitEvery = 1;

  final TextEditingController _cyclesController = TextEditingController(text: '3');
  final TextEditingController _waitUpController = TextEditingController(text: '5');
  final TextEditingController _waitDownController = TextEditingController(text: '5');
  final TextEditingController _waitEveryController = TextEditingController(text: '1');

  int cyclesCompleted = 0;
  int _currentCycleIndex = 0;
  String _currentPhase = 'idle';
  int _timeLeftSeconds = 0;
  String _statusMessage = 'Connect and start test';

  DateTime? _testStartTime;
  Timer? _idleTimer;
  Timer? _livePositionTimer;

  static const int _currentHeightRegister = 11503;
  static const int _toleranceMm = 5;
  static const Duration _movementTimeout = Duration(seconds: 180);
  static const Duration _movementCommandInterval = Duration(milliseconds: 980);
  static const Duration _positionPollInterval = Duration(milliseconds: 400);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initForegroundTask();

    ble.onDataReceived = _handleBleData;

    ble.onConnectionStateChanged = (bool connected) {
      if (!mounted) return;
      setState(() => isConnected = connected);
      if (!connected) {
        _stopIdleTimer();
        _stopLivePositionPolling();
        if (_testRunning && !_testPaused) {
          _testPaused = true;
          _currentPhase = 'paused';
          _saveSession();
          setState(() {});
        }
      } else {
        _startIdleTimer();
        _startLivePositionPolling();
        _readInitialRegisters();
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
    _waitUpController.dispose();
    _waitDownController.dispose();
    _waitEveryController.dispose();
    _idleTimer?.cancel();
    _livePositionTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      ble.isActuallyConnected.then((connected) {
        if (!mounted) return;
        setState(() => isConnected = connected);
        if (connected) {
          if (_idleTimer == null) _startIdleTimer();
          if (_livePositionTimer == null) _startLivePositionPolling();
          _readInitialRegisters();
        }
      });
    }
  }

  String _rxBuf = '';

  void _handleBleData(String msg) {
    _rxBuf += msg;
    while (true) {
      final nlIdx = _rxBuf.indexOf(RegExp(r'[\r\n]'));
      if (nlIdx == -1) break;
      final line = _rxBuf.substring(0, nlIdx).trim();
      _rxBuf = _rxBuf.substring(nlIdx + 1);
      if (line.isEmpty) continue;
      final match = RegExp(r'#?R?(\d+)\s*=\s*(-?\d+)').firstMatch(line);
      if (match == null) continue;
      final register = int.tryParse(match.group(1) ?? '');
      final value    = int.tryParse(match.group(2) ?? '');
      if (register == null || value == null) continue;
      bool changed = false;
      if (register == _currentHeightRegister) { currentHeight = value; changed = true; }
      else if (register == 20024) { minHeight = value; changed = true; }
      else if (register == 20025) { maxHeight = value; changed = true; }
      if (changed && mounted) setState(() {});
    }
  }

  void _startIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer.periodic(const Duration(seconds: 4), (t) {
      if ((!_testRunning || _testPaused) && isConnected && !_isPressed) {
        ble.sendCommand(Commands.idle);
      }
    });
  }

  void _stopIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  void _startLivePositionPolling() {
    _livePositionTimer?.cancel();
    _livePositionTimer = Timer.periodic(_positionPollInterval, (t) {
      if (isConnected) ble.sendCommand(Commands.readCurrentPosition);
    });
  }

  void _stopLivePositionPolling() {
    _livePositionTimer?.cancel();
    _livePositionTimer = null;
  }

  Future<void> _readInitialRegisters() async {
    if (!isConnected) return;
    if (!mounted) return;
    setState(() {
      _currentPhase = _testRunning ? _currentPhase : 'reading';
      _statusMessage = 'Reading min and max position...';
    });
    await ble.sendCommand(Commands.readCurrentPosition);
    await ble.sendCommand(Commands.readMinPosition);
    await ble.sendCommand(Commands.readMaxPosition);
    await Future.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;
    setState(() {
      if (!_testRunning) _currentPhase = 'idle';
      _statusMessage = 'Ready';
    });
  }

  bool _setValuesFromInput() {
    final cycles   = int.tryParse(_cyclesController.text.trim());
    final waitUp   = int.tryParse(_waitUpController.text.trim());
    final waitDown = int.tryParse(_waitDownController.text.trim());
    final waitEvery = int.tryParse(_waitEveryController.text.trim());
    if (cycles == null || cycles <= 0)   { _showMessage('Please enter a valid cycle count.'); return false; }
    if (waitUp == null || waitUp < 0)    { _showMessage('Please enter a valid Pause UP time.'); return false; }
    if (waitDown == null || waitDown < 0){ _showMessage('Please enter a valid Pause DOWN time.'); return false; }
    if (waitEvery == null || waitEvery <= 0){ _showMessage('Please enter a valid Wait every value.'); return false; }
    _cycles = cycles; _waitUpSeconds = waitUp; _waitDownSeconds = waitDown; _waitEvery = waitEvery;
    setState(() {});
    return true;
  }

  bool _controllerLimitsReady() {
    if (minHeight == null || maxHeight == null) { _showMessage('Min/Max not read yet. Connect and wait for values.'); return false; }
    if (maxHeight! <= minHeight!) { _showMessage('Invalid limits: MaxHeight must be greater than MinHeight.'); return false; }
    return true;
  }

  Future<bool> _moveToLimit({required bool goingUp}) async {
    if (!isConnected || !_controllerLimitsReady()) return false;
    final target  = goingUp ? maxHeight! : minHeight!;
    final command = goingUp ? Commands.up : Commands.down;
    setState(() {
      _currentPhase = goingUp ? 'up' : 'down';
      _timeLeftSeconds = 0;
      _statusMessage = goingUp ? 'Opening to MaxHeight' : 'Closing to MinHeight';
    });
    final startedAt = DateTime.now();
    Timer? movementTimer;
    ble.pauseKeepAlive();
    try {
      await ble.sendCommand(command, highPriority: true);
      movementTimer = Timer.periodic(_movementCommandInterval, (_) {
        if (_testRunning && !_testPaused && isConnected) ble.sendCommand(command, highPriority: true);
      });
      while (_testRunning && !_testPaused) {
        if (currentHeight != null) {
          final reached = goingUp ? currentHeight! >= target - _toleranceMm : currentHeight! <= target + _toleranceMm;
          if (reached) {
            setState(() { _statusMessage = goingUp ? 'MaxHeight reached: ${currentHeight!} mm' : 'MinHeight reached: ${currentHeight!} mm'; });
            return true;
          }
        }
        if (DateTime.now().difference(startedAt) >= _movementTimeout) {
          setState(() { _testPaused = true; _currentPhase = 'paused'; _statusMessage = 'Paused: target not reached within safety time.'; });
          return false;
        }
        await Future.delayed(const Duration(milliseconds: 50));
      }
      return false;
    } finally {
      movementTimer?.cancel();
      await ble.sendCommand(Commands.idle);
      if (!_testRunning || _testPaused) { ble.resumeKeepAlive(); _startIdleTimer(); }
    }
  }

  Future<bool> _waitAtLimit({required bool atTop}) async {
    final seconds = atTop ? _waitUpSeconds : _waitDownSeconds;
    setState(() { _currentPhase = atTop ? 'waitTop' : 'waitBottom'; _statusMessage = atTop ? 'Waiting at MaxHeight' : 'Waiting at MinHeight'; });
    await ble.sendCommand(Commands.idle);
    for (int remaining = seconds; remaining > 0; remaining--) {
      if (!_testRunning || _testPaused) return false;
      setState(() => _timeLeftSeconds = remaining);
      await ble.sendCommand(Commands.idle);
      await Future.delayed(const Duration(seconds: 1));
    }
    if (!mounted) return false;
    setState(() => _timeLeftSeconds = 0);
    return true;
  }

  Future<bool> _settleAtBottomWhenSkippingWait() async {
    setState(() { _currentPhase = 'settling'; _statusMessage = 'Settling at MinHeight'; });
    await ble.sendCommand(Commands.idle);
    for (int remaining = 2; remaining > 0; remaining--) {
      if (!_testRunning || _testPaused) return false;
      setState(() => _timeLeftSeconds = remaining);
      await ble.sendCommand(Commands.idle);
      await Future.delayed(const Duration(seconds: 1));
    }
    if (!mounted) return false;
    setState(() => _timeLeftSeconds = 0);
    return true;
  }

  Future<void> _saveSession() async {
    if (_testStartTime == null) return;
    await TestSession.saveOrUpdateSession(TestSession(
      umbrellaName: ble.connectedDeviceName,
      totalCycles: _cycles,
      completedCycles: cyclesCompleted,
      startTime: _testStartTime!,
      endTime: DateTime.now(),
    ));
  }

  Future<void> _startTest() async {
    if (!isConnected) return;
    if (_testRunning && !_testPaused) return;
    if (_testRunning && _testPaused) {
      _testPaused = false;
      _stopIdleTimer();
      ble.pauseKeepAlive();
      setState(() { _statusMessage = 'Resuming test'; });
    } else {
      if (!_setValuesFromInput()) return;
      await _readInitialRegisters();
      if (!_controllerLimitsReady()) return;
      cyclesCompleted = 0; _currentCycleIndex = 0; _currentPhase = 'up';
      _timeLeftSeconds = 0; _testRunning = true; _testPaused = false;
      _testStartTime = DateTime.now();
      _stopIdleTimer(); ble.pauseKeepAlive();
      await _saveSession();
      setState(() { _statusMessage = 'Test started'; });
    }
    while (_testRunning && _currentCycleIndex < _cycles) {
      if (_testPaused) { _startIdleTimer(); return; }
      if (_currentPhase == 'up') {
        final ok = await _moveToLimit(goingUp: true);
        if (!ok || !_testRunning || _testPaused) break;
        _currentPhase = 'waitTop';
      } else if (_currentPhase == 'waitTop') {
        final ok = await _waitAtLimit(atTop: true);
        if (!ok || !_testRunning || _testPaused) break;
        _currentPhase = 'down';
      } else if (_currentPhase == 'down') {
        final ok = await _moveToLimit(goingUp: false);
        if (!ok || !_testRunning || _testPaused) break;
        _currentPhase = 'waitBottom';
      } else if (_currentPhase == 'waitBottom') {
        final ok = (_currentCycleIndex + 1) % _waitEvery == 0
            ? await _waitAtLimit(atTop: false)
            : await _settleAtBottomWhenSkippingWait();
        if (!ok || !_testRunning || _testPaused) break;
        _currentCycleIndex++;
        cyclesCompleted = _currentCycleIndex;
        await _saveSession();
        setState(() {});
        _currentPhase = _currentCycleIndex < _cycles ? 'up' : 'finished';
      } else {
        _currentPhase = 'up';
      }
    }
    if (_testPaused) { _startIdleTimer(); return; }
    if (_testRunning) await _saveSession();
    _testRunning = false; _testPaused = false; _currentPhase = 'finished';
    _timeLeftSeconds = 0; _testStartTime = null;
    await ble.sendCommand(Commands.idle);
    ble.resumeKeepAlive(); _startIdleTimer();
    setState(() { _statusMessage = 'Test finished'; });
  }

  Future<void> _pauseTest() async {
    if (!_testRunning || _testPaused) return;
    _testPaused = true;
    await _saveSession();
    await ble.sendCommand(Commands.idle);
    ble.resumeKeepAlive(); _startIdleTimer();
    setState(() { _statusMessage = 'Paused'; });
  }

  Future<void> _stopTest() async {
    if (_testRunning) await _saveSession();
    _testRunning = false; _testPaused = false; _currentPhase = 'idle';
    _currentCycleIndex = 0; cyclesCompleted = 0; _timeLeftSeconds = 0; _testStartTime = null;
    await ble.sendCommand(Commands.idle);
    ble.resumeKeepAlive(); _startIdleTimer();
    setState(() { _statusMessage = 'Stopped'; });
  }

  Future<void> _startContinuousCommand(String cmd) async {
    if (!isConnected || (_testRunning && !_testPaused)) return;
    setState(() => _isPressed = true);
    _stopIdleTimer(); ble.pauseKeepAlive();
    while (_isPressed && isConnected) {
      await ble.sendCommand(cmd, highPriority: true);
      await Future.delayed(_movementCommandInterval);
    }
    await ble.sendCommand(Commands.idle);
    if (!_testRunning || _testPaused) { ble.resumeKeepAlive(); _startIdleTimer(); }
  }

  void _stopContinuousCommand() {
    setState(() => _isPressed = false);
    ble.emergencyStop(Commands.idle);
    Future.delayed(const Duration(milliseconds: 200), () {
      ble.sendCommand(Commands.idle);
      if (!_testRunning || _testPaused) { ble.resumeKeepAlive(); _startIdleTimer(); }
    });
  }

  Future<void> scanAndConnect() async {
    if (isConnected) {
      await ble.disconnect();
      _stopIdleTimer(); _stopLivePositionPolling();
      await _stopForegroundTask();
      setState(() { isConnected = false; _statusMessage = 'Disconnected'; });
    } else {
      final result = await Navigator.of(context).push(
        MaterialPageRoute(builder: (context) => DeviceSelectionPage(ble: ble)),
      );
      if (result == true) {
        await _startForegroundTask();
        final newState = await ble.isActuallyConnected;
        setState(() { isConnected = newState; _statusMessage = newState ? 'Connected' : 'Disconnected'; });
        if (isConnected) { _startIdleTimer(); _startLivePositionPolling(); await _readInitialRegisters(); }
      }
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  String _phaseText() {
    switch (_currentPhase) {
      case 'reading':    return 'Reading';
      case 'up':         return 'Opening';
      case 'waitTop':    return 'Wait Max';
      case 'down':       return 'Closing';
      case 'waitBottom': return 'Wait Min';
      case 'settling':   return 'Settling';
      case 'paused':     return 'Paused';
      case 'finished':   return 'Finished';
      default:           return 'Idle';
    }
  }

  String _heightText(int? value) => value == null ? '_____' : '$value mm';

  // =========================================================================
  // BUILD — only this section changed from your original.
  // All logic above is exactly what you pasted.
  // =========================================================================
  @override
  Widget build(BuildContext context) {
    final sw = MediaQuery.of(context).size.width;
    // Scale factor: 1.0 on a 390 px phone, smaller on narrow, larger on wide.
    // Clamped so nothing goes below 80 % or above 110 % of the base size.
    double s(double v) => (v * sw / 390).clamp(v * 0.80, v * 1.10);

    final controlsEnabled   = !_testRunning || _testPaused;
    final startEnabled      = isConnected && (!_testRunning || _testPaused);
    final disconnectEnabled = !_testRunning || _testPaused;

    // Left-panel width: 52 % of screen. Right panel: rest via Expanded.
    // This replaces the fixed 190 px and 150 px values.
    final leftW = sw * 0.52;

    return Scaffold(
      backgroundColor: Colors.grey[300],
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        toolbarHeight: 56,
        centerTitle: true,
        title: Image.asset('assets/ketterer_logo.png', height: 36, fit: BoxFit.contain),
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
                  Text('Hello',    style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
                  Text('Settings', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w500)),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.history, color: Colors.black54),
              title: const Text('Test History', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(context, MaterialPageRoute(builder: (context) => const SessionsPage()));
              },
            ),
            const ListTile(
              leading: Icon(Icons.language, color: Colors.black54),
              title: Text('Language', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(s(6)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [

              // Title
              Text('LMC Test App',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: s(15), fontWeight: FontWeight.bold, color: Colors.grey[600]),
              ),
              SizedBox(height: s(2)),

              // Status
              Text(
                isConnected ? 'Connected: ${ble.connectedDeviceName}' : 'Status: Disconnected',
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: s(13), fontWeight: FontWeight.w600,
                    color: isConnected ? Colors.green : Colors.red),
              ),
              SizedBox(height: s(6)),

              // ── Row 1: INPUTS | RESULTS ──────────────────────────────────
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [

                    // INPUTS
                    Container(
                      width: leftW,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 5, offset: Offset(0, 3))],
                      ),
                      padding: EdgeInsets.all(s(8)),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Center(child: Text('INPUTS',
                              style: TextStyle(fontSize: s(14), fontWeight: FontWeight.bold, color: Colors.grey))),
                          SizedBox(height: s(6)),
                          Text('Min:  ${_heightText(minHeight)}',  style: TextStyle(fontSize: s(13), fontWeight: FontWeight.bold)),
                          SizedBox(height: s(3)),
                          Text('Max:  ${_heightText(maxHeight)}',  style: TextStyle(fontSize: s(13), fontWeight: FontWeight.bold)),
                          SizedBox(height: s(3)),
                          Text('Curr: ${_heightText(currentHeight)}', style: TextStyle(fontSize: s(13), fontWeight: FontWeight.bold)),
                          Text('#GR=11503', style: TextStyle(fontSize: s(9), color: Colors.blueGrey)),
                          SizedBox(height: s(6)),
                          _inputRow('Cycles:',   _cyclesController,    null,  s),
                          SizedBox(height: s(4)),
                          _inputRow('Pause UP:', _waitUpController,    's',   s),
                          SizedBox(height: s(4)),
                          _inputRow('Pause DN:', _waitDownController,  's',   s),
                          SizedBox(height: s(4)),
                          _inputRow('Every:',    _waitEveryController, 'cyc', s),
                          SizedBox(height: s(6)),
                          SizedBox(
                            height: s(28),
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: (isConnected && !_testRunning) ? _readInitialRegisters : null,
                              icon: Icon(Icons.refresh, size: s(13)),
                              label: Text('Read Inputs',
                                  style: TextStyle(fontSize: s(11), fontWeight: FontWeight.bold)),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF5B6770),
                                foregroundColor: Colors.white,
                                padding: EdgeInsets.zero,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    SizedBox(width: s(5)),

                    // RESULTS
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 3))],
                        ),
                        padding: EdgeInsets.all(s(8)),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('RESULTS',
                                style: TextStyle(fontSize: s(13), fontWeight: FontWeight.bold, color: Colors.grey)),
                            SizedBox(height: s(6)),
                            Text('CYCLES COMPLETED:',
                                style: TextStyle(fontSize: s(9), fontWeight: FontWeight.bold,
                                    color: const Color(0xFFE96A1E))),
                            SizedBox(height: s(4)),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(cyclesCompleted.toString(),
                                  style: TextStyle(fontSize: s(36), fontWeight: FontWeight.bold, color: Colors.green)),
                            ),
                            SizedBox(height: s(6)),
                            Text('Phase: ${_phaseText()}',
                                style: TextStyle(fontSize: s(12), fontWeight: FontWeight.w600)),
                            SizedBox(height: s(2)),
                            Text(
                              _timeLeftSeconds > 0 ? 'Wait: ${_timeLeftSeconds}s' : _statusMessage,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: s(11), color: Colors.blueGrey, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              SizedBox(height: s(6)),

              // ── Row 2: CONTROLS | Start/Pause/Stop ───────────────────────
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [

                  // UP / DOWN
                  AbsorbPointer(
                    absorbing: !controlsEnabled || !isConnected,
                    child: Opacity(
                      opacity: (controlsEnabled && isConnected) ? 1.0 : 0.45,
                      child: Container(
                        width: leftW,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 3))],
                        ),
                        padding: EdgeInsets.symmetric(vertical: s(8), horizontal: s(4)),
                        child: Column(
                          children: [
                            Text('CONTROLS',
                                style: TextStyle(fontSize: s(13), fontWeight: FontWeight.bold, color: Colors.grey)),
                            SizedBox(height: s(6)),
                            Listener(
                              onPointerDown:   (_) => _startContinuousCommand(Commands.up),
                              onPointerUp:     (_) => _stopContinuousCommand(),
                              onPointerCancel: (_) => _stopContinuousCommand(),
                              child: _controlButton('UP', Icons.arrow_upward,
                                  isEnabled: controlsEnabled && isConnected, s: s),
                            ),
                            SizedBox(height: s(8)),
                            Listener(
                              onPointerDown:   (_) => _startContinuousCommand(Commands.down),
                              onPointerUp:     (_) => _stopContinuousCommand(),
                              onPointerCancel: (_) => _stopContinuousCommand(),
                              child: _controlButton('DOWN', Icons.arrow_downward,
                                  isEnabled: controlsEnabled && isConnected, s: s),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  SizedBox(width: s(8)),

                  // Start / Pause / Stop — fills remaining width
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ElevatedButton.icon(
                          onPressed: startEnabled ? _startTest : null,
                          icon: Icon(_testPaused ? Icons.play_arrow : Icons.play_circle_fill, size: s(18)),
                          label: Text(_testPaused ? 'Resume' : 'Start',
                              style: TextStyle(fontSize: s(14), fontWeight: FontWeight.bold)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: startEnabled ? const Color(0xFFE96A1E) : Colors.grey,
                            foregroundColor: Colors.white,
                            padding: EdgeInsets.symmetric(vertical: s(10)),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                        SizedBox(height: s(8)),
                        ElevatedButton.icon(
                          onPressed: (_testRunning && !_testPaused) ? _pauseTest : null,
                          icon: Icon(Icons.pause, size: s(18)),
                          label: Text('Pause',
                              style: TextStyle(fontSize: s(14), fontWeight: FontWeight.bold)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: (_testRunning && !_testPaused) ? Colors.amber : Colors.grey,
                            foregroundColor: Colors.white,
                            padding: EdgeInsets.symmetric(vertical: s(10)),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                        SizedBox(height: s(8)),
                        ElevatedButton.icon(
                          onPressed: _testRunning ? _stopTest : null,
                          icon: Icon(Icons.stop, size: s(18)),
                          label: Text('Stop',
                              style: TextStyle(fontSize: s(14), fontWeight: FontWeight.bold)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _testRunning ? const Color(0xFFE96A1E) : Colors.grey,
                            foregroundColor: Colors.white,
                            padding: EdgeInsets.symmetric(vertical: s(10)),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              SizedBox(height: s(14)),

              // Connect / Disconnect
              ElevatedButton.icon(
                onPressed: disconnectEnabled ? scanAndConnect : null,
                icon: Icon(isConnected ? Icons.bluetooth_disabled : Icons.bluetooth),
                label: Text(isConnected ? 'Disconnect' : 'Connect',
                    style: TextStyle(fontSize: s(18), fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: disconnectEnabled ? const Color(0xFFE96A1E) : Colors.grey,
                  foregroundColor: Colors.white,
                  minimumSize: Size(double.infinity, s(52)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Input row: label + text field
  Widget _inputRow(String label, TextEditingController controller, String? suffix, double Function(double) s) {
    return Row(
      children: [
        SizedBox(
          width: 62,
          child: Text(label, style: TextStyle(fontSize: s(11), fontWeight: FontWeight.bold)),
        ),
        Expanded(
          child: SizedBox(
            height: s(26),
            child: TextField(
              controller: controller,
              keyboardType: const TextInputType.numberWithOptions(decimal: false),
              style: TextStyle(fontSize: s(12)),
              decoration: InputDecoration(
                suffixText: suffix,
                suffixStyle: TextStyle(fontSize: s(10)),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // UP / DOWN hold button
  Widget _controlButton(String label, IconData icon, {required bool isEnabled, required double Function(double) s}) {
    return Container(
      alignment: Alignment.center,
      padding: EdgeInsets.symmetric(vertical: s(12)),
      decoration: BoxDecoration(
        color: isEnabled ? const Color(0xFFE96A1E) : Colors.grey,
        borderRadius: BorderRadius.circular(6),
        boxShadow: isEnabled
            ? const [BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 3))]
            : null,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: Colors.white, size: s(20)),
          SizedBox(width: s(6)),
          Text(label, style: TextStyle(color: Colors.white, fontSize: s(16), fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}