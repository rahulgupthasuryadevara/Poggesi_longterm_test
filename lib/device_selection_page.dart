import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'bluetooth_helper.dart';

class DeviceSelectionPage extends StatefulWidget {
  final BluetoothHelper ble;

  const DeviceSelectionPage({super.key, required this.ble});

  @override
  State<DeviceSelectionPage> createState() => _DeviceSelectionPageState();
}

class _DeviceSelectionPageState extends State<DeviceSelectionPage> {
  List<ScanResult> _scanResults = [];
  bool _isScanning = false;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  Future<void> _startScan() async {
    setState(() {
      _isScanning = true;
      _scanResults = [];
    });

    try {
      await widget.ble.startScan();

      FlutterBluePlus.scanResults.listen((results) {
        if (mounted) {
          setState(() {
            _scanResults = results;
          });
        }
      });

      FlutterBluePlus.isScanning.listen((scanning) {
        if (mounted) {
          setState(() {
            _isScanning = scanning;
          });
        }
      });
    } catch (e) {
      debugPrint("Scan error: $e");
    }
  }

  bool _isConnecting = false;

  Future<void> _connectToDevice(BluetoothDevice device) async {
    // Guard against double-taps while a connection is already in progress.
    if (_isConnecting) return;
    _isConnecting = true;

    // Show the loading spinner on the ROOT navigator. This keeps it on a
    // separate navigator from this page, so dismissing the spinner can never
    // accidentally pop (or fail to pop) this selection page.
    showDialog(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (_) => const Center(
        child: CircularProgressIndicator(color: Color(0xFFE96A1E)),
      ),
    );

    bool success = false;
    try {
      success = await widget.ble.connectToDevice(device);
    } catch (e) {
      debugPrint("Connect error: $e");
      success = false;
    }

    // Double-check the real connection state — connectToDevice's return value
    // can be falsely negative on a slow connection that actually succeeded.
    if (!success) {
      try {
        success = await widget.ble.isActuallyConnected;
      } catch (_) {}
    }

    if (!mounted) return;

    // Close the spinner on the root navigator (the one we opened it on).
    Navigator.of(context, rootNavigator: true).pop();

    // Let the dialog finish dismissing before we navigate this page away.
    // Without this small gap the two navigations can race.
    await Future.delayed(const Duration(milliseconds: 150));

    if (!mounted) {
      _isConnecting = false;
      return;
    }

    if (success) {
      Navigator.of(context).pop(true); // back to main page
    } else {
      _isConnecting = false;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Failed to connect")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final filteredResults = _scanResults.where((r) {
      final name = r.device.platformName;
      return name.contains('LMC');
    }).toList();

    return Scaffold(
      backgroundColor: Colors.grey[300],
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        toolbarHeight: 60,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Image.asset(
          'assets/ketterer_logo.png',
          height: 40,
          fit: BoxFit.contain,
        ),
        actions: [
          if (_isScanning)
            const Center(
              child: Padding(
                padding: EdgeInsets.only(right: 16.0),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFFE96A1E),
                  ),
                ),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh, color: Colors.black),
              onPressed: _startScan,
            )
        ],
      ),
      body: Column(
        children: [
          const SizedBox(height: 10),
          Center(
            child: Text(
              'AVAILABLE DEVICES',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.grey[600],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: filteredResults.isEmpty && !_isScanning
                ? Center(
              child: Text(
                "No LMC devices found nearby",
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey[600],
                ),
              ),
            )
                : ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              itemCount: filteredResults.length,
              itemBuilder: (context, index) {
                final result = filteredResults[index];
                final deviceName = result.device.platformName;

                return Container(
                  margin: const EdgeInsets.symmetric(vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(15),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black26,
                        blurRadius: 5,
                        offset: Offset(0, 3),
                      )
                    ],
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 15,
                      vertical: 5,
                    ),
                    title: Text(
                      deviceName,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    subtitle: Text(
                      result.device.remoteId.toString(),
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[600],
                      ),
                    ),
                    trailing: ElevatedButton(
                      onPressed: () => _connectToDevice(result.device),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFE96A1E),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 15,
                        ),
                      ),
                      child: const Text(
                        "CONNECT",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}