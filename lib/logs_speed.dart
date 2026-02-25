import 'package:flutter/material.dart';
import 'main.dart';

class Logs4Page extends StatelessWidget {
  final List<Map<String, dynamic>> logs;

  const Logs4Page({super.key, required this.logs});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Test Logs"),
        backgroundColor: const Color(0xFFE96A1E),
      ),
      body: logs.isEmpty
          ? const Center(
        child: Text(
          "No logs yet",
          style: TextStyle(fontSize: 18),
        ),
      )
          : ListView.builder(
        itemCount: logs.length,
        itemBuilder: (context, index) {
          final item = logs[index];
          final cycle = item['cycle'];
          final value4 = item['value4'];

          return Card(
            margin:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: ListTile(
              leading: const Icon(Icons.timeline),
              title: Text(
                "Cycle: $cycle",
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              subtitle: Text(
                "speed : $value4",
                style: const TextStyle(fontSize: 16),
              ),
            ),
          );
        },
      ),
    );
  }
}
