class Commands {
  static const up   = '#CMD up 0\n';
  static const down = '#CMD down 0\n';
  static const idle = '#CMD idle 0\n';

  static const readCurrentPosition = '#GR=11503\n';
  static const readMotorMoving     = '#GR=12503\n';  // 1 = moving, 0 = stopped
  static const readMinPosition     = '#GR=20024\n';
  static const readMaxPosition     = '#GR=20025\n';

  static const light_on1 = '#R4100=1\n';
  static String light_on(int value) => '#R31087=$value\n';
  static const light_off = '#R4100=0\n';
}