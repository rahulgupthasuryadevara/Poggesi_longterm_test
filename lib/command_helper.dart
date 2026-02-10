class Commands{
  static const up="#CMD up 0\n";
  static const down="#CMD down 0\n";
  static const light_on1="#R4100=1\n";
  static String light_on(int value) => "#R31087=$value\n";
  static const light_off="#R4100=0\n";
  static const idle="#CMD idle 0\n";

//LTC
/*static const up="#CMD up\n";
  static const down="#CMD down\n";
  static const light_on1="#R4100=1\n";
  static String light_on(int value) => "#R31087=$value\n";
  static const light_off="#R4100=0\n";
  static const idle="#CMD stop\n";*/




}