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

  bool isConnected  = false;
  bool _testRunning = false;
  bool _testPaused  = false;
  bool _isPressed   = false;

  // Info-only — displayed but NOT used for movement control

  // User inputs
  int _cycles          = 3;
  int _openTimeSec     = 41;   // how long to send UP command
  int _closeTimeSec    = 42;   // how long to send DOWN command
  int _waitUpSeconds   = 5;    // pause at top
  int _waitDownSeconds = 5;    // pause at bottom
  int _waitEvery       = 1;

  final TextEditingController _cyclesController    = TextEditingController(text: '3');
  final TextEditingController _openTimeController  = TextEditingController(text: '41');
  final TextEditingController _closeTimeController = TextEditingController(text: '42');
  final TextEditingController _waitUpController    = TextEditingController(text: '5');
  final TextEditingController _waitDownController  = TextEditingController(text: '5');
  final TextEditingController _waitEveryController = TextEditingController(text: '1');

  int    cyclesCompleted  = 0;
  int    _currentCycleIndex = 0;
  String _currentPhase    = 'idle';
  int    _timeLeftSeconds = 0;
  String _statusMessage   = 'Connect and start test';

  DateTime? _testStartTime;
  Timer?    _idleTimer;

  // Motor-moving register — read during movement as safety cross-check only
  int? _isMotorMoving;

  static const Duration _movementCommandInterval = Duration(milliseconds: 980);
  // How often to cross-check 12503 during movement
  static const Duration _motorCheckInterval      = Duration(seconds: 2);

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
        if (_testRunning && !_testPaused) {
          _testPaused   = true;
          _currentPhase = 'paused';
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
    _openTimeController.dispose();
    _closeTimeController.dispose();
    _waitUpController.dispose();
    _waitDownController.dispose();
    _waitEveryController.dispose();
    _idleTimer?.cancel();
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
        }
      });
    }
  }

  // ── BLE data handler ──────────────────────────────────────────────────────
  // Only parses what we care about. 12503 is stored but never triggers rebuild.
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

      if (register == 12503) {
        _isMotorMoving = value; // internal only — no rebuild
      }
    }
  }

  // ── Idle / keep-alive ─────────────────────────────────────────────────────
  void _startIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if ((!_testRunning || _testPaused) && isConnected && !_isPressed) {
        ble.sendCommand(Commands.idle);
      }
    });
  }

  void _stopIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  // ── Validate inputs ───────────────────────────────────────────────────────
  bool _setValuesFromInput() {
    final cycles    = int.tryParse(_cyclesController.text.trim());
    final openTime  = int.tryParse(_openTimeController.text.trim());
    final closeTime = int.tryParse(_closeTimeController.text.trim());
    final waitUp    = int.tryParse(_waitUpController.text.trim());
    final waitDown  = int.tryParse(_waitDownController.text.trim());
    final waitEvery = int.tryParse(_waitEveryController.text.trim());

    if (cycles == null || cycles <= 0)      { _showMessage('Enter a valid cycle count.');    return false; }
    if (openTime == null || openTime <= 0)  { _showMessage('Enter a valid open time (s).');  return false; }
    if (closeTime == null || closeTime <= 0){ _showMessage('Enter a valid close time (s).'); return false; }
    if (waitUp == null || waitUp < 0)       { _showMessage('Enter a valid Pause UP time.');  return false; }
    if (waitDown == null || waitDown < 0)   { _showMessage('Enter a valid Pause DN time.');  return false; }
    if (waitEvery == null || waitEvery <= 0){ _showMessage('Enter a valid Wait every.');     return false; }

    _cycles          = cycles;
    _openTimeSec     = openTime;
    _closeTimeSec    = closeTime;
    _waitUpSeconds   = waitUp;
    _waitDownSeconds = waitDown;
    _waitEvery       = waitEvery;
    setState(() {});
    return true;
  }

  // ── TIMING-BASED MOVEMENT ─────────────────────────────────────────────────
  //
  // Logic:
  //   1. Send #CMD up/down 0, repeat every ~980ms for the full open/close time
  //   2. Every 2 seconds, cross-check register 12503 (isMotorMoving)
  //      If it reports 0 (stopped) unexpectedly → wait 1s → resend command
  //   3. When time is up → send idle → done
  //
  // No position polling during movement = no queue pressure = responsive UI.
  // ─────────────────────────────────────────────────────────────────────────
  Future<bool> _move({required bool goingUp}) async {
    if (!isConnected) return false;

    final command      = goingUp ? Commands.up : Commands.down;
    final durationSec  = goingUp ? _openTimeSec : _closeTimeSec;
    final phaseLabel   = goingUp ? 'up' : 'down';
    final statusLabel  = goingUp ? 'Opening...' : 'Closing...';

    setState(() {
      _currentPhase    = phaseLabel;
      _timeLeftSeconds = durationSec;
      _statusMessage   = statusLabel;
    });

    ble.pauseKeepAlive();

    Timer? movementTimer;
    Timer? motorCheckTimer;
    DateTime? stalledAt;
    int stallRetries = 0;
    const maxStallRetries = 5;

    try {
      await ble.sendCommand(command, highPriority: true);
      movementTimer = Timer.periodic(_movementCommandInterval, (_) {
        if (_testRunning && !_testPaused && isConnected) {
          ble.sendCommand(command, highPriority: true);
        }
      });

      motorCheckTimer = Timer.periodic(_motorCheckInterval, (_) async {
        if (!_testRunning || _testPaused || !isConnected) return;
        await ble.sendCommand(Commands.readMotorMoving);
      });

      for (int remaining = durationSec; remaining > 0; remaining--) {
        if (!_testRunning || _testPaused) return false;

        setState(() => _timeLeftSeconds = remaining);

        if (_isMotorMoving == 0) {
          if (stalledAt == null) {
            // Motor just stopped — show message and start 2s settling wait.
            // This covers natural direction-switching (up→down) where the
            // motor needs a moment before it accepts the next command.
            stalledAt = DateTime.now();
            setState(() => _statusMessage = 'Motor stopped! Waiting 2s...');
          } else if (DateTime.now().difference(stalledAt!) >= const Duration(seconds: 2)) {
            // Still stopped after 2s — send a retry
            if (stallRetries < maxStallRetries) {
              stallRetries++;
              setState(() => _statusMessage =
              'Retry $stallRetries/$maxStallRetries — sending command...');
              // Send idle first (same as Pause does), then the move command.
              // Controller ignores repeated move commands when stopped/reset —
              // it needs idle → move, exactly like Pause→Resume does.
              await ble.sendCommand(Commands.idle, highPriority: true);
              await Future.delayed(const Duration(milliseconds: 500));
              await ble.sendCommand(command, highPriority: true);
              stalledAt = DateTime.now();
            } else {
              // All retries exhausted, motor still not moving — end reached.
              setState(() => _statusMessage =
              'Motor stopped after $maxStallRetries retries — end reached.');
              return true;
            }
          }
        } else {
          if (stalledAt != null) {
            // Motor is moving again — clear stall state and show normal status.
            stallRetries = 0;
            stalledAt = null;
            setState(() => _statusMessage = goingUp ? 'Opening...' : 'Closing...');
          }
        }

        await Future.delayed(const Duration(seconds: 1));
      }

      if (!mounted) return false;
      setState(() {
        _timeLeftSeconds = 0;
        _statusMessage   = goingUp ? 'Open complete' : 'Close complete';
      });
      return true;

    } finally {
      movementTimer?.cancel();
      motorCheckTimer?.cancel();
      _isMotorMoving = null; // reset for next move
      await ble.sendCommand(Commands.idle, highPriority: true);
      if (!_testRunning || _testPaused) {
        ble.resumeKeepAlive();
        _startIdleTimer();
      }
    }
  }

  // ── Wait at limit ─────────────────────────────────────────────────────────
  Future<bool> _waitAtLimit({required bool atTop}) async {
    final seconds = atTop ? _waitUpSeconds : _waitDownSeconds;
    setState(() {
      _currentPhase  = atTop ? 'waitTop' : 'waitBottom';
      _statusMessage = atTop ? 'Waiting at top' : 'Waiting at bottom';
    });
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

  Future<bool> _settleAtBottom() async {
    setState(() {
      _currentPhase  = 'settling';
      _statusMessage = 'Settling...';
    });
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

  // ── Session save ──────────────────────────────────────────────────────────
  Future<void> _saveSession() async {
    if (_testStartTime == null) return;
    await TestSession.saveOrUpdateSession(TestSession(
      umbrellaName:     ble.connectedDeviceName,
      totalCycles:      _cycles,
      completedCycles:  cyclesCompleted,
      startTime:        _testStartTime!,
      endTime:          DateTime.now(),
    ));
  }

  // ── Start / Resume test ───────────────────────────────────────────────────
  Future<void> _startTest() async {
    if (!isConnected) return;
    if (_testRunning && !_testPaused) return;

    if (_testRunning && _testPaused) {
      _testPaused = false;
      _stopIdleTimer();
      ble.pauseKeepAlive();
      setState(() { _statusMessage = 'Resuming...'; });
    } else {
      if (!_setValuesFromInput()) return;
      cyclesCompleted    = 0;
      _currentCycleIndex = 0;
      _currentPhase      = 'up';
      _timeLeftSeconds   = 0;
      _testRunning       = true;
      _testPaused        = false;
      _testStartTime     = DateTime.now();
      _stopIdleTimer();
      ble.pauseKeepAlive();
      await _saveSession();
      setState(() { _statusMessage = 'Test started'; });
    }

    while (_testRunning && _currentCycleIndex < _cycles) {
      if (_testPaused) { _startIdleTimer(); return; }

      if (_currentPhase == 'up') {
        final ok = await _move(goingUp: true);
        if (!ok || !_testRunning || _testPaused) break;
        _currentPhase = 'waitTop';

      } else if (_currentPhase == 'waitTop') {
        final ok = await _waitAtLimit(atTop: true);
        if (!ok || !_testRunning || _testPaused) break;
        _currentPhase = 'down';

      } else if (_currentPhase == 'down') {
        final ok = await _move(goingUp: false);
        if (!ok || !_testRunning || _testPaused) break;
        _currentPhase = 'waitBottom';

      } else if (_currentPhase == 'waitBottom') {
        final ok = (_currentCycleIndex + 1) % _waitEvery == 0
            ? await _waitAtLimit(atTop: false)
            : await _settleAtBottom();
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

    _testRunning     = false;
    _testPaused      = false;
    _currentPhase    = 'finished';
    _timeLeftSeconds = 0;
    _testStartTime   = null;
    await ble.sendCommand(Commands.idle);
    ble.resumeKeepAlive();
    _startIdleTimer();
    setState(() { _statusMessage = 'Test finished'; });
  }

  Future<void> _pauseTest() async {
    if (!_testRunning || _testPaused) return;
    _testPaused = true;
    await _saveSession();
    await ble.sendCommand(Commands.idle);
    ble.resumeKeepAlive();
    _startIdleTimer();
    setState(() { _statusMessage = 'Paused'; });
  }

  Future<void> _stopTest() async {
    if (_testRunning) await _saveSession();
    _testRunning       = false;
    _testPaused        = false;
    _currentPhase      = 'idle';
    _currentCycleIndex = 0;
    cyclesCompleted    = 0;
    _timeLeftSeconds   = 0;
    _testStartTime     = null;
    await ble.sendCommand(Commands.idle);
    ble.resumeKeepAlive();
    _startIdleTimer();
    setState(() { _statusMessage = 'Stopped'; });
  }

  // ── Manual UP/DOWN hold buttons ───────────────────────────────────────────
  Future<void> _startContinuousCommand(String cmd) async {
    if (!isConnected || (_testRunning && !_testPaused)) return;
    setState(() => _isPressed = true);
    _stopIdleTimer();
    ble.pauseKeepAlive();
    while (_isPressed && isConnected) {
      await ble.sendCommand(cmd, highPriority: true);
      await Future.delayed(_movementCommandInterval);
    }
    await ble.sendCommand(Commands.idle);
    if (!_testRunning || _testPaused) {
      ble.resumeKeepAlive();
      _startIdleTimer();
    }
  }

  void _stopContinuousCommand() {
    setState(() => _isPressed = false);
    ble.emergencyStop(Commands.idle);
    Future.delayed(const Duration(milliseconds: 200), () {
      ble.sendCommand(Commands.idle);
      if (!_testRunning || _testPaused) {
        ble.resumeKeepAlive();
        _startIdleTimer();
      }
    });
  }

  // ── Connect / Disconnect ──────────────────────────────────────────────────
  Future<void> scanAndConnect() async {
    if (isConnected) {
      await ble.disconnect();
      _stopIdleTimer();
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
        if (isConnected) {
          _startIdleTimer();
        }
      }
    }
  }

  void _showMessage(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _phaseText() {
    switch (_currentPhase) {
      case 'up':         return 'Opening';
      case 'waitTop':    return 'Wait Top';
      case 'down':       return 'Closing';
      case 'waitBottom': return 'Wait Bottom';
      case 'settling':   return 'Settling';
      case 'paused':     return 'Paused';
      case 'finished':   return 'Finished';
      default:           return 'Idle';
    }
  }

  // =========================================================================
  // BUILD
  // =========================================================================
  @override
  Widget build(BuildContext context) {
    final sw = MediaQuery.of(context).size.width;
    double s(double v) => (v * sw / 390).clamp(v * 0.80, v * 1.10);

    final controlsEnabled   = !_testRunning || _testPaused;
    final startEnabled      = isConnected && (!_testRunning || _testPaused);
    final disconnectEnabled = !_testRunning || _testPaused;
    final leftW             = sw * 0.52;

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
              title: const Text('Test History', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(context, MaterialPageRoute(builder: (_) => const SessionsPage()));
              },
            ),
            const ListTile(
              leading: Icon(Icons.language, color: Colors.black54),
              title: Text('Language', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
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

              // Title + status
              Text('LMC Test App',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: s(14), fontWeight: FontWeight.bold, color: Colors.grey[600]),
              ),
              SizedBox(height: s(2)),
              Text(
                isConnected ? 'Connected: ${ble.connectedDeviceName}' : 'Disconnected',
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: s(12), fontWeight: FontWeight.w600,
                    color: isConnected ? Colors.green : Colors.red),
              ),
              SizedBox(height: s(6)),

              // ── Row 1: INPUTS | RESULTS ──────────────────────────────────
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [

                    // INPUTS card
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
                              style: TextStyle(fontSize: s(13), fontWeight: FontWeight.bold, color: Colors.grey))),
                          SizedBox(height: s(4)),


                          _inputRow('Cycles:',   _cyclesController,    null, s),
                          SizedBox(height: s(4)),
                          _inputRow('Open (s):', _openTimeController,  's',  s),
                          SizedBox(height: s(4)),
                          _inputRow('Close (s):',_closeTimeController, 's',  s),
                          SizedBox(height: s(4)),
                          _inputRow('Pause UP:', _waitUpController,    's',  s),
                          SizedBox(height: s(4)),
                          _inputRow('Pause DN:', _waitDownController,  's',  s),
                          SizedBox(height: s(4)),
                          _inputRow('Every:',    _waitEveryController, 'cyc',s),
                        ],
                      ),
                    ),

                    SizedBox(width: s(5)),

                    // RESULTS card
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
                                  style: TextStyle(fontSize: s(38), fontWeight: FontWeight.bold, color: Colors.green)),
                            ),
                            SizedBox(height: s(6)),
                            Text('Phase: ${_phaseText()}',
                                style: TextStyle(fontSize: s(11), fontWeight: FontWeight.w600)),
                            SizedBox(height: s(2)),
                            Text(
                              _timeLeftSeconds > 0 ? 'Time left: ${_timeLeftSeconds}s' : _statusMessage,
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

                  // UP / DOWN hold buttons
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

                  // Start / Pause / Stop
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
                label: Text(
                  isConnected ? 'Disconnect' : 'Connect',
                  style: TextStyle(fontSize: s(17), fontWeight: FontWeight.bold),
                ),
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

  // ── Input row ─────────────────────────────────────────────────────────────
  Widget _inputRow(String label, TextEditingController controller, String? suffix, double Function(double) s) {
    return Row(
      children: [
        SizedBox(
          width: 66,
          child: Text(label, style: TextStyle(fontSize: s(10), fontWeight: FontWeight.bold)),
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

  // ── UP / DOWN hold button ─────────────────────────────────────────────────
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