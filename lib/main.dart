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
      title: 'EnduraTest',
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
  int? _isMotorMoving; // register 12503: 1 = moving, 0 = stopped

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
  static const int _toleranceMm = 40;     // target reached tolerance (mm)
  static const int _moveDetectMm = 5;    // min change to count as 'moved' (mm)
  int _failedCyclesInRow = 0;             // consecutive failed cycles
  static const Duration _movementTimeout = Duration(seconds: 180);
  static const Duration _movementCommandInterval = Duration(milliseconds: 980);
  static const Duration _positionPollInterval = Duration(milliseconds: 700); // matched to controller reply rate (avoids stale-reply backlog)

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
          _startLivePositionPolling();
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
      if (register == _currentHeightRegister) {
        currentHeight = value; changed = true;
        _onPositionReplyReceived(); // got the reply → send next poll
      }
      else if (register == 12503) { _isMotorMoving = value; } // internal only, no rebuild
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

  // ── REQUEST-RESPONSE POSITION POLLING ─────────────────────────────────────
  // Instead of firing position reads on a blind timer (which builds a backlog
  // of stale replies when the controller is slow), we send ONE read, then wait
  // for its reply before sending the next. This means the display always shows
  // the freshest value the controller can give, and lag can never accumulate.
  //
  // A safety timeout re-issues the read if a reply never comes back, so the
  // loop can't get permanently stuck on a dropped packet.
  bool   _livePollRunning   = false;
  bool   _awaitingPosition  = false;
  Timer? _positionTimeout;

  void _startLivePositionPolling() {
    if (_livePollRunning) return;
    _livePollRunning = true;
    _sendPositionPoll();
  }

  void _stopLivePositionPolling() {
    _livePollRunning  = false;
    _awaitingPosition = false;
    _positionTimeout?.cancel();
    _positionTimeout = null;
    _livePositionTimer?.cancel();
    _livePositionTimer = null;
  }

  void _sendPositionPoll() {
    if (!_livePollRunning || !isConnected) return;
    _awaitingPosition = true;
    ble.sendCommand(Commands.readCurrentPosition, highPriority: true);

    // Safety net: if no reply arrives within 1s, send the next poll anyway.
    _positionTimeout?.cancel();
    _positionTimeout = Timer(const Duration(seconds: 1), () {
      if (_livePollRunning) {
        _awaitingPosition = false;
        _sendPositionPoll();
      }
    });
  }

  // Called from _handleBleData the instant a position (11503) reply arrives.
  void _onPositionReplyReceived() {
    if (!_livePollRunning) return;
    _awaitingPosition = false;
    _positionTimeout?.cancel();
    // Immediately request the next position. A tiny delay keeps the queue from
    // being hammered back-to-back and gives motor/idle commands room.
    Future.delayed(const Duration(milliseconds: 60), _sendPositionPoll);
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

  // Input limits — enforced before a test can start.
  static const int _maxCycles      = 3500; // maximum cycle count
  static const int _minPauseUp     = 3;    // Pause UP minimum (seconds)
  static const int _minPauseDown   = 3;    // Pause DOWN minimum (seconds)
  static const int _minWaitEvery   = 1;    // Every minimum
  static const int _maxWaitEvery   = 5;    // Every maximum

  bool _setValuesFromInput() {
    final cycles    = int.tryParse(_cyclesController.text.trim());
    final waitUp    = int.tryParse(_waitUpController.text.trim());
    final waitDown  = int.tryParse(_waitDownController.text.trim());
    final waitEvery = int.tryParse(_waitEveryController.text.trim());

    // Cycles: 1 .. 3500
    if (cycles == null || cycles <= 0) {
      _showMessage('Please enter a valid cycle count (1 to $_maxCycles).');
      return false;
    }
    if (cycles > _maxCycles) {
      _showMessage('Cycle count cannot exceed $_maxCycles.');
      return false;
    }

    // Pause UP: minimum 3 s
    if (waitUp == null || waitUp < _minPauseUp) {
      _showMessage('Pause UP must be at least $_minPauseUp seconds.');
      return false;
    }

    // Pause DOWN: minimum 3 s
    if (waitDown == null || waitDown < _minPauseDown) {
      _showMessage('Pause DOWN must be at least $_minPauseDown seconds.');
      return false;
    }

    // Every: 1 .. 5
    if (waitEvery == null || waitEvery < _minWaitEvery || waitEvery > _maxWaitEvery) {
      _showMessage('Wait every must be between $_minWaitEvery and $_maxWaitEvery.');
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
    if (minHeight == null || maxHeight == null) { _showMessage('Min/Max not read yet. Connect and wait for values.'); return false; }
    if (maxHeight! <= minHeight!) { _showMessage('Invalid limits: MaxHeight must be greater than MinHeight.'); return false; }
    return true;
  }

  // ── POSITION-BASED MOVEMENT with STALL RECOVERY ───────────────────────────
  //
  // Source of truth = the real position (currentHeight, register 11503).
  //   • Going UP   → done when currentHeight >= maxHeight - tolerance
  //   • Going DOWN → done when currentHeight <= minHeight + tolerance
  //
  // Stall recovery:
  //   While moving we watch the position. If it stops changing for ~3s AND the
  //   target isn't reached, we treat it as a stall (firmware glitch / power
  //   blip). We "kick" the motor exactly like a manual Pause→Resume does:
  //   send idle → wait 500ms → resend the up/down command. Up to 3 kicks.
  //   If the position still won't move after 3 kicks, we assume the motor hit
  //   the physical end of travel and finish successfully.
  //
  //   Register 12503 (_isMotorMoving) is polled as a secondary confirmation.
  //
  // The 180s safety timeout remains as the final backstop.
  // ─────────────────────────────────────────────────────────────────────────
  Future<bool> _moveToLimit({required bool goingUp}) async {
    if (!isConnected || !_controllerLimitsReady()) return false;

    final target  = goingUp ? maxHeight! : minHeight!;
    final command = goingUp ? Commands.up : Commands.down;
    final label   = goingUp ? 'Opening to MaxHeight' : 'Closing to MinHeight';

    setState(() {
      _currentPhase    = goingUp ? 'up' : 'down';
      _timeLeftSeconds = 0;
      _statusMessage   = label;
    });

    final startedAt = DateTime.now();
    Timer? movementTimer;
    Timer? motorPollTimer;

    // Stall tracking
    int?     lastPosition;          // position at the previous progress check
    DateTime lastProgressAt = DateTime.now();
    int      stallRetries   = 0;
    const    maxStallRetries = 3;
    const    stallThreshold  = Duration(seconds: 3); // no movement this long = stalled
    const    startupGrace    = Duration(seconds: 5); // ignore stall checks for first 5s

    ble.pauseKeepAlive();

    try {
      // Start movement: send once, then keep re-sending every ~1s
      await ble.sendCommand(command, highPriority: true);
      movementTimer = Timer.periodic(_movementCommandInterval, (_) {
        if (_testRunning && !_testPaused && isConnected) {
          ble.sendCommand(command, highPriority: true);
        }
      });

      // Secondary check: poll the motor-moving register every 1s
      motorPollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_testRunning && !_testPaused && isConnected) {
          ble.sendCommand(Commands.readMotorMoving);
        }
      });

      while (_testRunning && !_testPaused) {
        // 1. Reached target by position? → success
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

        // 2. Progress detection — has the position changed since last check?
        //    Skip entirely during the first few seconds of the phase, because
        //    the position register takes a moment to start updating. Without
        //    this grace period the motor would look "frozen" at the very start
        //    and trigger a false stall.
        final inStartupGrace =
            DateTime.now().difference(startedAt) < startupGrace;

        if (!inStartupGrace && currentHeight != null) {
          // Count as "moved" only if the position changed by more than the
          // detection tolerance. Small wobbles (<= _moveDetectMm) are treated
          // as still frozen, so noisy readings don't hide a real stall.
          final movedEnough = lastPosition == null ||
              (currentHeight! - lastPosition!).abs() > _moveDetectMm;

          if (movedEnough) {
            // Position moved (or first reading) → reset stall timer
            lastPosition   = currentHeight;
            lastProgressAt = DateTime.now();
            if (stallRetries != 0) {
              // We had been stalled and now recovered
              stallRetries = 0;
              setState(() => _statusMessage = label);
            }
          } else {
            // Position unchanged — check how long it's been frozen.
            // A frozen position is the PRIMARY stall signal and is enough on
            // its own to trigger a retry. Register 12503 is only an extra hint:
            // if it explicitly says the motor is MOVING (1), we hold off, in
            // case the position reading is just lagging. But if 12503 is 0 or
            // null/unknown, a frozen position still counts as a stall.
            final frozenFor = DateTime.now().difference(lastProgressAt);
            final motorSaysMoving = _isMotorMoving == 1;

            // DEBUG: watch this in the console to see stall detection working.
            debugPrint('[STALL CHECK] pos=$currentHeight last=$lastPosition '
                'frozenForMs=${frozenFor.inMilliseconds} '
                '12503=$_isMotorMoving retries=$stallRetries');

            if (frozenFor >= stallThreshold && !motorSaysMoving) {
              if (stallRetries < maxStallRetries) {
                stallRetries++;
                setState(() => _statusMessage =
                'Motor stopped — retry $stallRetries/$maxStallRetries...');

                // Kick the motor by REPLICATING a manual Pause -> Resume, which
                // is known to work. The key is a real GAP of idle between the
                // stop and the restart — sending idle then move back-to-back is
                // too fast and the controller ignores the move.
                //
                //   1. Stop the periodic move timer so it doesn't fight us.
                //   2. Send idle and HOLD it for ~1.5s (the "pause").
                //   3. Send the move command a few times in a row (the "resume"),
                //      so the controller definitely latches onto it.
                //   4. Restart the periodic move timer.

                movementTimer?.cancel();

                // 2. Idle hold — this is the settling gap that makes it work.
                await ble.sendCommand(Commands.idle, highPriority: true);
                await Future.delayed(const Duration(milliseconds: 800));
                await ble.sendCommand(Commands.idle, highPriority: true);
                await Future.delayed(const Duration(milliseconds: 800));

                // 3. Resume — send the move command several times to latch it.
                for (int k = 0; k < 3; k++) {
                  if (!_testRunning || _testPaused) break;
                  await ble.sendCommand(command, highPriority: true);
                  await Future.delayed(const Duration(milliseconds: 300));
                }

                // 4. Restart the periodic move stream.
                movementTimer = Timer.periodic(_movementCommandInterval, (_) {
                  if (_testRunning && !_testPaused && isConnected) {
                    ble.sendCommand(command, highPriority: true);
                  }
                });

                // Give the motor a moment, then measure a fresh freeze window.
                await Future.delayed(const Duration(milliseconds: 1000));
                lastProgressAt = DateTime.now();
              } else {
                // 3 kicks done, motor still won't move. Decide if this is the
                // real end of travel (close to target = OK) or a genuine
                // failure (far from target = move failed).
                final pos = currentHeight ?? 0;
                final reachedTarget = goingUp
                    ? pos >= target - _toleranceMm
                    : pos <= target + _toleranceMm;

                if (reachedTarget) {
                  // Close enough — treat as a normal successful end of travel.
                  setState(() => _statusMessage = goingUp
                      ? 'Top reached (end of travel): $pos mm'
                      : 'Bottom reached (end of travel): $pos mm');
                  return true;
                } else {
                  // Far from target — this move FAILED.
                  setState(() => _statusMessage = goingUp
                      ? 'MOVE FAILED — did not reach top ($pos mm)'
                      : 'MOVE FAILED — did not reach bottom ($pos mm)');
                  return false;
                }
              }
            }
          }
        }

        // While still in the startup grace window, keep the stall clock fresh
        // so the 3-second freeze timer only starts counting once grace ends.
        if (inStartupGrace) {
          lastPosition   = currentHeight;
          lastProgressAt = DateTime.now();
        }

        // 3. Final safety backstop
        if (DateTime.now().difference(startedAt) >= _movementTimeout) {
          setState(() {
            _testPaused    = true;
            _currentPhase  = 'paused';
            _statusMessage = 'Paused: target not reached within safety time.';
          });
          return false;
        }

        await Future.delayed(const Duration(milliseconds: 200));
      }
      return false;
    } finally {
      movementTimer?.cancel();
      motorPollTimer?.cancel();
      _isMotorMoving = null;
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

  // ── SAFETY CONFIRMATION ───────────────────────────────────────────────────
  // Shown when the user presses Start (only for a fresh test, not Resume).
  // The user must tick every checkbox before the dialog's Start button enables.
  Future<void> _confirmAndStart() async {
    // If this is a resume (test already running but paused), skip the dialog.
    if (_testRunning && _testPaused) {
      _startTest();
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _SafetyDialog(),
    );

    if (confirmed == true) {
      _startTest();
    }
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
      _failedCyclesInRow = 0;
      _timeLeftSeconds = 0; _testRunning = true; _testPaused = false;
      _testStartTime = DateTime.now();
      _stopIdleTimer(); ble.pauseKeepAlive();
      await _saveSession();
      setState(() { _statusMessage = 'Test started'; });
    }
    // Tracks whether the CURRENT cycle had any failed move (up or down).
    bool cycleHadFailure = false;

    while (_testRunning && _currentCycleIndex < _cycles) {
      if (_testPaused) { _startIdleTimer(); return; }

      if (_currentPhase == 'up') {
        final ok = await _moveToLimit(goingUp: true);
        // Pause/stop/disconnect → exit. A FAILED move does NOT break; we note
        // it and carry on so failures can accumulate across cycles.
        if (!_testRunning || _testPaused) break;
        if (!ok) cycleHadFailure = true;
        _currentPhase = 'waitTop';

      } else if (_currentPhase == 'waitTop') {
        final ok = await _waitAtLimit(atTop: true);
        if (!ok || !_testRunning || _testPaused) break;
        _currentPhase = 'down';

      } else if (_currentPhase == 'down') {
        final ok = await _moveToLimit(goingUp: false);
        if (!_testRunning || _testPaused) break;
        if (!ok) cycleHadFailure = true;
        _currentPhase = 'waitBottom';

      } else if (_currentPhase == 'waitBottom') {
        final ok = (_currentCycleIndex + 1) % _waitEvery == 0
            ? await _waitAtLimit(atTop: false)
            : await _settleAtBottomWhenSkippingWait();
        if (!ok || !_testRunning || _testPaused) break;

        // End of this cycle — update the consecutive-failure counter.
        if (cycleHadFailure) {
          _failedCyclesInRow++;
        } else {
          _failedCyclesInRow = 0; // a good cycle resets the streak
        }

        _currentCycleIndex++;
        cyclesCompleted = _currentCycleIndex;
        await _saveSession();
        setState(() {});

        // 3 failed cycles in a row → abort the whole test.
        if (_failedCyclesInRow >= 3) {
          _testRunning  = false;
          _testPaused   = false;
          _currentPhase = 'finished';
          await ble.sendCommand(Commands.idle);
          ble.resumeKeepAlive();
          _startIdleTimer();
          setState(() => _statusMessage =
          'TEST FAILED — 3 cycles failed in a row. Please restart.');
          return;
        }

        cycleHadFailure = false; // reset for the next cycle
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
              )
            ),
            ListTile(
              leading: const Icon(Icons.history, color: Colors.black54),
              title: const Text('Test History', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(context, MaterialPageRoute(builder: (context) => const SessionsPage()));
              },
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
              Text('EnduraTest',
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
                          onPressed: startEnabled ? _confirmAndStart : null,
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

// ═══════════════════════════════════════════════════════════════════════════
// SAFETY CONFIRMATION DIALOG
//
// A scrollable popup shown before a test starts. Lists numbered safety
// instructions, each with a checkbox. The "START TEST" button stays disabled
// until ALL checkboxes are ticked. Returns true via Navigator.pop when the
// user confirms, or false/null if cancelled.
// ═══════════════════════════════════════════════════════════════════════════
class _SafetyDialog extends StatefulWidget {
  const _SafetyDialog();

  @override
  State<_SafetyDialog> createState() => _SafetyDialogState();
}

class _SafetyDialogState extends State<_SafetyDialog> {
  // Each safety instruction the user must acknowledge.
  final List<String> _instructions = const [
    'Keep yourself and all personnel clear of the umbrella before and during the test.',
    'Make sure all cables (power and programming) are properly and securely connected.',
    'Set up the testing area with barriers and cones around the umbrella, exactly as shown in the image below.',
    'Ensure there are no obstructions in the umbrella\'s opening and closing path.',
    'Do not approach or touch the umbrella while the test is running.',
    'Ketterer is not responsible for any injury, damage, or consequence arising from improper setup or failure to follow these instructions.',
  ];

  // Tick state for each instruction.
  late final List<bool> _checked =
  List<bool>.filled(_instructions.length, false);

  bool get _allChecked => _checked.every((c) => c);

  @override
  Widget build(BuildContext context) {
    final sw = MediaQuery.of(context).size.width;
    double s(double v) => (v * sw / 390).clamp(v * 0.85, v * 1.10);

    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: EdgeInsets.symmetric(horizontal: s(16), vertical: s(24)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Header ────────────────────────────────────────────────────
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(s(14)),
              decoration: const BoxDecoration(
                color: Color(0xFFE96A1E),
                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.white, size: s(26)),
                  SizedBox(width: s(10)),
                  Expanded(
                    child: Text(
                      'SAFETY INSTRUCTIONS',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: s(17),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ── Scrollable body ───────────────────────────────────────────
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(s(14)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Please read and confirm each point before starting the test:',
                      style: TextStyle(
                        fontSize: s(13),
                        fontWeight: FontWeight.w600,
                        color: Colors.grey[700],
                      ),
                    ),
                    SizedBox(height: s(10)),

                    // Numbered checkboxes
                    ...List.generate(_instructions.length, (i) {
                      return Padding(
                        padding: EdgeInsets.only(bottom: s(6)),
                        child: InkWell(
                          onTap: () => setState(() => _checked[i] = !_checked[i]),
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: EdgeInsets.all(s(8)),
                            decoration: BoxDecoration(
                              color: _checked[i]
                                  ? const Color(0xFFE96A1E).withOpacity(0.08)
                                  : Colors.grey[100],
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: _checked[i]
                                    ? const Color(0xFFE96A1E)
                                    : Colors.grey.shade300,
                                width: 1,
                              ),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: s(22),
                                  height: s(22),
                                  child: Checkbox(
                                    value: _checked[i],
                                    activeColor: const Color(0xFFE96A1E),
                                    materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                    onChanged: (v) =>
                                        setState(() => _checked[i] = v ?? false),
                                  ),
                                ),
                                SizedBox(width: s(10)),
                                Expanded(
                                  child: Text(
                                    '${i + 1}. ${_instructions[i]}',
                                    style: TextStyle(
                                      fontSize: s(12.5),
                                      height: 1.3,
                                      color: Colors.black87,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }),

                    SizedBox(height: s(10)),

                    // Safety zone image
                    Text(
                      'Required testing area setup:',
                      style: TextStyle(
                        fontSize: s(12.5),
                        fontWeight: FontWeight.bold,
                        color: Colors.grey[700],
                      ),
                    ),
                    SizedBox(height: s(8)),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.asset(
                        'assets/safety_zone.png',
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => Container(
                          height: s(120),
                          alignment: Alignment.center,
                          color: Colors.grey[200],
                          child: Text(
                            'safety_zone.png not found in assets',
                            style: TextStyle(fontSize: s(11), color: Colors.grey[600]),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ── Footer buttons ────────────────────────────────────────────
            Padding(
              padding: EdgeInsets.all(s(12)),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.grey[700],
                        padding: EdgeInsets.symmetric(vertical: s(12)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                      child: Text('CANCEL',
                          style: TextStyle(
                              fontSize: s(13), fontWeight: FontWeight.bold)),
                    ),
                  ),
                  SizedBox(width: s(10)),
                  Expanded(
                    child: ElevatedButton(
                      // Disabled until every box is ticked.
                      onPressed: _allChecked
                          ? () => Navigator.of(context).pop(true)
                          : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor:
                        _allChecked ? const Color(0xFFE96A1E) : Colors.grey,
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.symmetric(vertical: s(12)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                      child: Text('START TEST',
                          style: TextStyle(
                              fontSize: s(13), fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}