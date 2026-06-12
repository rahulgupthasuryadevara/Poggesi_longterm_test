import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class TestSession {
  final String umbrellaName;
  final int totalCycles;
  final int completedCycles;
  final DateTime startTime;
  final DateTime endTime;

  TestSession({
    required this.umbrellaName,
    required this.totalCycles,
    required this.completedCycles,
    required this.startTime,
    required this.endTime,
  });

  Map<String, dynamic> toJson() => {
    'umbrellaName': umbrellaName,
    'totalCycles': totalCycles,
    'completedCycles': completedCycles,
    'startTime': startTime.toIso8601String(),
    'endTime': endTime.toIso8601String(),
  };

  factory TestSession.fromJson(Map<String, dynamic> json) => TestSession(
    umbrellaName: json['umbrellaName'],
    totalCycles: json['totalCycles'],
    completedCycles: json['completedCycles'],
    startTime: DateTime.parse(json['startTime']),
    endTime: DateTime.parse(json['endTime']),
  );

  static Future<void> saveOrUpdateSession(TestSession session) async {
    final prefs = await SharedPreferences.getInstance();
    final String? sessionsJson = prefs.getString('test_sessions');
    List<dynamic> sessionsList = sessionsJson != null ? jsonDecode(sessionsJson) : [];
    
    // Check if this session (by startTime) already exists in the list
    int existingIndex = sessionsList.indexWhere((s) => 
      TestSession.fromJson(s).startTime.isAtSameMomentAs(session.startTime)
    );

    if (existingIndex != -1) {
      // Update existing record
      sessionsList[existingIndex] = session.toJson();
    } else {
      // Add new record at the top
      sessionsList.insert(0, session.toJson());
    }
    
    await prefs.setString('test_sessions', jsonEncode(sessionsList));
  }

  static Future<List<TestSession>> loadSessions() async {
    final prefs = await SharedPreferences.getInstance();
    final String? sessionsJson = prefs.getString('test_sessions');
    if (sessionsJson == null) return [];
    List<dynamic> sessionsList = jsonDecode(sessionsJson);
    return sessionsList.map((item) => TestSession.fromJson(item)).toList();
  }
}
