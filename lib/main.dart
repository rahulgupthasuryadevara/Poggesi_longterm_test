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
  bool _readingInitialRegisters = false;

  // Values read automatically from the controller.
  int? minHeight; // #R20024=
  int? maxHeight; // #R20025=
  int? currentHeight; // live value from the expert-style current-height register

  // User inputs. Height values are read automatically from the controller.
  int _cycles = 3;
  int _waitUpSeconds = 5;
  int _waitDownSeconds = 5;
  int _waitEvery = 1; // Perform bottom pause every X cycles

  final TextEditingController _cyclesController = TextEditingController(text: '3');
  final TextEditingController _waitUpController = TextEditingController(text: '5');
  final TextEditingController _waitDownController = TextEditingController(text: '5');
  final TextEditingController _waitEveryController = TextEditingController(text: '1');

  int cyclesCompleted = 0;
  int _currentCycleIndex = 0;
  String _currentPhase = 'idle'; // idle, reading, up, waitTop, down, waitBottom, paused, finished
  int _timeLeftSeconds = 0;
  String _statusMessage = 'Connect and start test';

  DateTime? _testStartTime;
  Timer? _idleTimer;
  Timer? _livePositionTimer;
  String _rxBuffer = '';

  // Expert Mode used a simple auto-refresh loop: enter register, toggle auto,
  // then keep reading that exact register while the motor moves.
  // We use the same idea here for CurrHeight.
  static const int _currentHeightRegister = 11503;

  // Hidden internal safety values. They are not user inputs.
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

  void _handleBleData(String msg) {
    // BLE notifications can arrive as full lines or as partial fragments.
    // Buffer them so the UI is updated from the newest complete register value.
    _rxBuffer += msg;

    final lines = _rxBuffer.split(RegExp(r'[\r\n]+'));
    final endsWithLineBreak = _rxBuffer.endsWith('\n') || _rxBuffer.endsWith('\r');
    if (endsWithLineBreak) {
      _rxBuffer = '';
    } else {
      _rxBuffer = lines.isNotEmpty ? lines.removeLast() : '';
    }

    bool changed = false;

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      final match = RegExp(r'#?R?(\d+)\s*=\s*(-?\d+)').firstMatch(line);
      if (match == null) continue;

      final register = int.tryParse(match.group(1) ?? '');
      final value = int.tryParse(match.group(2) ?? '');
      if (register == null || value == null) continue;

      if (register == _currentHeightRegister) {
        currentHeight = value;
        changed = true;
      } else if (register == 20024) {
        minHeight = value;
        changed = true;
      } else if (register == 20025) {
        maxHeight = value;
        changed = true;
      }
    }

    if (changed && mounted) setState(() {});
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
      if (isConnected && !_readingInitialRegisters) {
        // Same concept as Expert Mode Auto: keep reading the selected register
        // continuously, even while the motor is moving. Movement commands are
        // sent separately and much less often.
        ble.sendCommand(Commands.readCurrentPosition);
      }
    });
  }

  void _stopLivePositionPolling() {
    _livePositionTimer?.cancel();
    _livePositionTimer = null;
  }

  Future<void> _readInitialRegisters() async {
    if (!isConnected || _readingInitialRegisters) return;

    setState(() {
      _readingInitialRegisters = true;
      _currentPhase = _testRunning ? _currentPhase : 'reading';
      _statusMessage = 'Reading current, min and max position...';
    });

    // Expert Mode pauses keep-alive during a manual register refresh. Do the
    // same here so the three reads are not delayed behind idle/keepalive writes.
    ble.pauseKeepAlive();
    try {
      await ble.sendCommand(Commands.readCurrentPosition);
      await Future.delayed(const Duration(milliseconds: 120));
      await ble.sendCommand(Commands.readMinPosition);
      await Future.delayed(const Duration(milliseconds: 120));
      await ble.sendCommand(Commands.readMaxPosition);
      await Future.delayed(const Duration(milliseconds: 250));
    } finally {
      ble.resumeKeepAlive();
    }

    if (!mounted) return;
    setState(() {
      _readingInitialRegisters = false;
      if (!_testRunning) _currentPhase = 'idle';
      _statusMessage = 'Ready';
    });
  }

  bool _setValuesFromInput() {
    final cycles = int.tryParse(_cyclesController.text.trim());
    final waitUp = int.tryParse(_waitUpController.text.trim());
    final waitDown = int.tryParse(_waitDownController.text.trim());
    final waitEvery = int.tryParse(_waitEveryController.text.trim());

    if (cycles == null || cycles <= 0) {
      _showMessage('Please enter a valid cycle count.');
      return false;
    }

    if (waitUp == null || waitUp < 0) {
      _showMessage('Please enter a valid Pause UP time.');
      return false;
    }

    if (waitDown == null || waitDown < 0) {
      _showMessage('Please enter a valid Pause DOWN time.');
      return false;
    }

    if (waitEvery == null || waitEvery <= 0) {
      _showMessage('Please enter a valid Wait every value.');
      return false;
    }

    _cycles = cycles;
    _waitUpSeconds = waitUp;
    _waitDownSeconds = waitDown;
    _waitEvery = waitEvery;
    setState(() {});
    return true;
  }

  bool _controllerLimitsReady() {
    if (minHeight == null || maxHeight == null) {
      _showMessage('Min/Max not read yet. Connect and wait for values.');
      return false;
    }

    if (maxHeight! <= minHeight!) {
      _showMessage('Invalid limits: MaxHeight must be greater than MinHeight.');
      return false;
    }

    return true;
  }

  Future<bool> _moveToLimit({required bool goingUp}) async {
    if (!isConnected || !_controllerLimitsReady()) return false;

    final target = goingUp ? maxHeight! : minHeight!;
    final command = goingUp ? Commands.up : Commands.down;
    final phase = goingUp ? 'up' : 'down';
    final text = goingUp ? 'Opening to MaxHeight' : 'Closing to MinHeight';

    setState(() {
      _currentPhase = phase;
      _timeLeftSeconds = 0;
      _statusMessage = text;
    });

    final startedAt = DateTime.now();
    Timer? movementTimer;

    // IMPORTANT:
    // BluetoothHelper has its own keep-alive timer that sends #CMD idle 0.
    // During automatic UP/DOWN movement we must pause it, otherwise it can
    // interrupt the motor every few seconds and create move-stop-move behavior.
    ble.pauseKeepAlive();

    try {
      // Same idea as Expert Mode: send the movement command as a continuous
      // hold stream. The live height polling timer runs independently and keeps
      // reading #GR=11503 every ~400 ms.
      await ble.sendCommand(command);
      movementTimer = Timer.periodic(_movementCommandInterval, (_) {
        if (_testRunning && !_testPaused && isConnected) {
          ble.sendCommand(command);
        }
      });

      while (_testRunning && !_testPaused) {
        if (currentHeight != null) {
          final reached = goingUp
              ? currentHeight! >= target - _toleranceMm
              : currentHeight! <= target + _toleranceMm;

          if (reached) {
            setState(() {
              _statusMessage = goingUp
                  ? 'MaxHeight reached: ${currentHeight!} mm'
                  : 'MinHeight reached: ${currentHeight!} mm';
            });
            return true;
          }
        }

        final elapsed = DateTime.now().difference(startedAt);
        if (elapsed >= _movementTimeout) {
          setState(() {
            _testPaused = true;
            _currentPhase = 'paused';
            _statusMessage = 'Paused: target not reached within safety time.';
          });
          return false;
        }

        await Future.delayed(const Duration(milliseconds: 50));
      }

      return false;
    } finally {
      movementTimer?.cancel();
      await ble.sendCommand(Commands.idle);

      // Do not resume helper keep-alive while the automatic test continues.
      // Wait phases send idle intentionally. Keep-alive is resumed only when
      // the test is paused, stopped, or finished.
      if (!_testRunning || _testPaused) {
        ble.resumeKeepAlive();
        _startIdleTimer();
      }
    }
  }

  Future<bool> _waitAtLimit({required bool atTop}) async {
    final seconds = atTop ? _waitUpSeconds : _waitDownSeconds;
    setState(() {
      _currentPhase = atTop ? 'waitTop' : 'waitBottom';
      _statusMessage = atTop ? 'Waiting at MaxHeight' : 'Waiting at MinHeight';
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

  Future<bool> _settleAtBottomWhenSkippingWait() async {
    setState(() {
      _currentPhase = 'settling';
      _statusMessage = 'Settling at MinHeight';
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

  Future<void> _saveSession() async {
    if (_testStartTime == null) return;

    final session = TestSession(
      umbrellaName: ble.connectedDeviceName,
      totalCycles: _cycles,
      completedCycles: cyclesCompleted,
      startTime: _testStartTime!,
      endTime: DateTime.now(),
    );

    await TestSession.saveOrUpdateSession(session);
  }

  Future<void> _startTest() async {
    if (!isConnected) return;

    if (_testRunning && !_testPaused) return;

    if (_testRunning && _testPaused) {
      _testPaused = false;
      _stopIdleTimer();
      ble.pauseKeepAlive();
      setState(() {
        _statusMessage = 'Resuming test';
      });
    } else {
      if (!_setValuesFromInput()) return;
      await _readInitialRegisters();
      if (!_controllerLimitsReady()) return;

      cyclesCompleted = 0;
      _currentCycleIndex = 0;
      _currentPhase = 'up';
      _timeLeftSeconds = 0;
      _testRunning = true;
      _testPaused = false;
      _testStartTime = DateTime.now();
      _stopIdleTimer();
      ble.pauseKeepAlive();
      await _saveSession();
      setState(() {
        _statusMessage = 'Test started';
      });
    }

    while (_testRunning && _currentCycleIndex < _cycles) {
      if (_testPaused) {
        _startIdleTimer();
        return;
      }

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
        final currentCycleNum = _currentCycleIndex + 1;
        final bool shouldDoFullBottomWait = currentCycleNum % _waitEvery == 0;

        final ok = shouldDoFullBottomWait
            ? await _waitAtLimit(atTop: false)
            : await _settleAtBottomWhenSkippingWait();
        if (!ok || !_testRunning || _testPaused) break;

        _currentCycleIndex++;
        cyclesCompleted = _currentCycleIndex;
        await _saveSession();
        setState(() {});

        if (_currentCycleIndex < _cycles) {
          _currentPhase = 'up';
        } else {
          _currentPhase = 'finished';
        }
      } else {
        _currentPhase = 'up';
      }
    }

    if (_testPaused) {
      _startIdleTimer();
      return;
    }

    if (_testRunning) await _saveSession();

    _testRunning = false;
    _testPaused = false;
    _currentPhase = 'finished';
    _timeLeftSeconds = 0;
    _testStartTime = null;
    await ble.sendCommand(Commands.idle);
    ble.resumeKeepAlive();
    _startIdleTimer();
    setState(() {
      _statusMessage = 'Test finished';
    });
  }

  Future<void> _pauseTest() async {
    if (!_testRunning || _testPaused) return;

    _testPaused = true;
    await _saveSession();
    await ble.sendCommand(Commands.idle);
    ble.resumeKeepAlive();
    _startIdleTimer();
    setState(() {
      _statusMessage = 'Paused';
    });
  }

  Future<void> _stopTest() async {
    if (_testRunning) await _saveSession();

    _testRunning = false;
    _testPaused = false;
    _currentPhase = 'idle';
    _currentCycleIndex = 0;
    cyclesCompleted = 0;
    _timeLeftSeconds = 0;
    _testStartTime = null;

    await ble.sendCommand(Commands.idle);
    ble.resumeKeepAlive();
    _startIdleTimer();
    setState(() {
      _statusMessage = 'Stopped';
    });
  }

  Future<void> _startContinuousCommand(String cmd) async {
    if (!isConnected || (_testRunning && !_testPaused)) return;

    setState(() => _isPressed = true);
    _stopIdleTimer();
    ble.pauseKeepAlive();

    // Same as Expert Mode manual movement: send the command repeatedly while
    // the button is held. Height polling continues independently.
    while (_isPressed && isConnected) {
      await ble.sendCommand(cmd);
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

  Future<void> scanAndConnect() async {
    if (isConnected) {
      await ble.disconnect();
      _stopIdleTimer();
      _stopLivePositionPolling();
      await _stopForegroundTask();
      setState(() {
        isConnected = false;
        _statusMessage = 'Disconnected';
      });
    } else {
      final result = await Navigator.of(context).push(
        MaterialPageRoute(builder: (context) => DeviceSelectionPage(ble: ble)),
      );
      if (result == true) {
        await _startForegroundTask();
        final newState = await ble.isActuallyConnected;
        setState(() {
          isConnected = newState;
          _statusMessage = newState ? 'Connected' : 'Disconnected';
        });
        if (isConnected) {
          _startIdleTimer();
          _startLivePositionPolling();
          await _readInitialRegisters();
        }
      }
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  String _phaseText() {
    switch (_currentPhase) {
      case 'reading':
        return 'Reading';
      case 'up':
        return 'Opening';
      case 'waitTop':
        return 'Wait Max';
      case 'down':
        return 'Closing';
      case 'waitBottom':
        return 'Wait Min';
      case 'settling':
        return 'Settling';
      case 'paused':
        return 'Paused';
      case 'finished':
        return 'Finished';
      default:
        return 'Idle';
    }
  }

  String _heightText(int? value) => value == null ? '_____' : '$value mm';

  @override
  Widget build(BuildContext context) {
    final controlsEnabled = !_testRunning || _testPaused;
    final startEnabled = isConnected && (!_testRunning || _testPaused);
    final disconnectEnabled = !_testRunning || _testPaused;
    const labelStyle = TextStyle(fontSize: 16, fontWeight: FontWeight.bold);

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
                    height: 300,
                    width: 190,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(15),
                      boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 5, offset: Offset(0, 3))],
                    ),
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Center(child: Text('INPUTS', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.grey))),
                        const SizedBox(height: 8),
                        Text('MinHeight: ${_heightText(minHeight)}', style: labelStyle),
                        const SizedBox(height: 5),
                        Text('MaxHeight: ${_heightText(maxHeight)}', style: labelStyle),
                        const SizedBox(height: 5),
                        Text('CurrHeight: ${_heightText(currentHeight)}', style: labelStyle),
                        const SizedBox(height: 2),
                        const Text('Curr source: #GR=11503', style: TextStyle(fontSize: 10, color: Colors.blueGrey)),
                        const SizedBox(height: 8),
                        _inputRow('Cycles:', _cyclesController, null),
                        const SizedBox(height: 5),
                        _inputRow('Pause UP:', _waitUpController, 's'),
                        const SizedBox(height: 5),
                        _inputRow('Pause DOWN:', _waitDownController, 's'),
                        const SizedBox(height: 5),
                        _inputRow('Wait every:', _waitEveryController, 'cyc'),
                        const SizedBox(height: 5),
                        SizedBox(
                          height: 30,
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: (isConnected && !_testRunning && !_readingInitialRegisters)
                                ? _readInitialRegisters
                                : null,
                            icon: const Icon(Icons.refresh, size: 14),
                            label: const Text('Read Inputs', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF5B6770),
                              foregroundColor: Colors.white,
                              padding: EdgeInsets.zero,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                            ),
                          ),
                        ),
                        if (_readingInitialRegisters)
                          const Text('Reading values...', style: TextStyle(fontSize: 11, color: Colors.blueGrey)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Container(
                      height: 300,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 3))],
                      ),
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        children: [
                          const Text('RESULTS', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.grey)),
                          const SizedBox(height: 8),
                          const Text('CYCLES COMPLETED:', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFFE96A1E))),
                          const SizedBox(height: 4),
                          Text(cyclesCompleted.toString(), style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold, color: Colors.green)),
                          const SizedBox(height: 6),
                          Text('Phase: ${_phaseText()}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 2),
                          Text(_timeLeftSeconds > 0 ? 'Wait left: ${_timeLeftSeconds}s' : _statusMessage, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: Colors.blueGrey, fontWeight: FontWeight.bold)),
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
                    absorbing: !controlsEnabled || !isConnected,
                    child: Opacity(
                      opacity: (controlsEnabled && isConnected) ? 1 : 0.45,
                      child: Container(
                        height: 170,
                        width: 150,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 3))],
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 3),
                        child: Column(
                          children: [
                            const Text('CONTROLS', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.grey)),
                            const SizedBox(height: 5),
                            Listener(
                              onPointerDown: (_) => _startContinuousCommand(Commands.up),
                              onPointerUp: (_) => _stopContinuousCommand(),
                              onPointerCancel: (_) => _stopContinuousCommand(),
                              child: _controlButton('UP', Icons.arrow_upward, isEnabled: controlsEnabled && isConnected),
                            ),
                            const SizedBox(height: 10),
                            Listener(
                              onPointerDown: (_) => _startContinuousCommand(Commands.down),
                              onPointerUp: (_) => _stopContinuousCommand(),
                              onPointerCancel: (_) => _stopContinuousCommand(),
                              child: _controlButton('DOWN', Icons.arrow_downward, isEnabled: controlsEnabled && isConnected),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 15),
                  Column(
                    children: [
                      ElevatedButton.icon(
                        onPressed: startEnabled ? _startTest : null,
                        icon: Icon(_testPaused ? Icons.play_arrow : Icons.play_circle_fill),
                        label: Text(_testPaused ? 'Resume' : 'Start', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: startEnabled ? const Color(0xFFE96A1E) : Colors.grey,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(110, 40),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                      const SizedBox(height: 10),
                      ElevatedButton.icon(
                        onPressed: (_testRunning && !_testPaused) ? _pauseTest : null,
                        icon: const Icon(Icons.pause),
                        label: const Text('Pause', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: (_testRunning && !_testPaused) ? Colors.amber : Colors.grey,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(110, 40),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                      const SizedBox(height: 10),
                      ElevatedButton.icon(
                        onPressed: _testRunning ? _stopTest : null,
                        icon: const Icon(Icons.stop),
                        label: const Text('Stop', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _testRunning ? const Color(0xFFE96A1E) : Colors.grey,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(110, 40),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
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
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _inputRow(String label, TextEditingController controller, String? suffix) {
    return Row(
      children: [
        SizedBox(
          width: 82,
          child: Text(
            label,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
          ),
        ),
        Expanded(
          child: SizedBox(
            height: 28,
            child: TextField(
              controller: controller,
              keyboardType: const TextInputType.numberWithOptions(decimal: false),
              decoration: InputDecoration(
                suffixText: suffix,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
        ),
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
        boxShadow: isEnabled ? const [BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 3))] : null,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: Colors.white),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
