import 'package:flutter/material.dart';
import 'test_session.dart';
import 'package:intl/intl.dart';

class SessionsPage extends StatefulWidget {
  const SessionsPage({super.key});

  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage> {
  List<TestSession> _sessions = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    final sessions = await TestSession.loadSessions();
    setState(() {
      _sessions = sessions;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Test History'),
        backgroundColor: const Color(0xFFE96A1E),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _sessions.isEmpty
              ? const Center(child: Text('No saved sessions'))
              : ListView.builder(
                  itemCount: _sessions.length,
                  itemBuilder: (context, index) {
                    final session = _sessions[index];
                    final dateFormat = DateFormat('yyyy-MM-dd HH:mm');
                    return Card(
                      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      child: ListTile(
                        title: Text(session.umbrellaName, style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Cycles: ${session.completedCycles} / ${session.totalCycles}'),
                            Text('From: ${dateFormat.format(session.startTime)}'),
                            Text('To: ${dateFormat.format(session.endTime)}'),
                          ],
                        ),
                        isThreeLine: true,
                        leading: Icon(
                          session.completedCycles == session.totalCycles
                              ? Icons.check_circle
                              : Icons.warning,
                          color: session.completedCycles == session.totalCycles
                              ? Colors.green
                              : Colors.orange,
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
