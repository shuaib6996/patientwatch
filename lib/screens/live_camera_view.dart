import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../models/patient.dart';
import '../services/auth_service.dart';

class LiveCameraView extends StatefulWidget {
  final Patient patient;

  const LiveCameraView({Key? key, required this.patient}) : super(key: key);

  @override
  State<LiveCameraView> createState() => _LiveCameraViewState();
}

class _LiveCameraViewState extends State<LiveCameraView> {
  final AuthService _authService = AuthService();
  StreamSubscription? _mjpegSubscription;
  Uint8List? _latestFrame;
  bool _isError = false;
  bool _isTargetLocked = false;

  @override
  void initState() {
    super.initState();
    _startMjpegStream();
    _checkInitialTargetStatus();
  }

  Future<void> _checkInitialTargetStatus() async {
    try {
      final url = Uri.parse('http://100.97.64.92:8000/cameras/target/status?camera_id=${widget.patient.deviceId}');
      final resp = await http.get(url).timeout(const Duration(seconds: 2));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (mounted && data is Map && data['locked'] == true) {
          setState(() => _isTargetLocked = true);
        }
      }
    } catch (_) {}
  }

  Future<void> _lockTargetAt(double normX, double normY) async {
    try {
      final url = Uri.parse('http://100.97.64.92:8000/cameras/target/lock');
      final resp = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'camera_id': widget.patient.deviceId,
          'x': normX,
          'y': normY,
        }),
      ).timeout(const Duration(seconds: 3));
      if (resp.statusCode == 200 && mounted) {
        setState(() => _isTargetLocked = true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('🎯 Target Patient Locked! System focusing on patient.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error locking target: $e');
    }
  }

  Future<void> _toggleTargetLock() async {
    if (_isTargetLocked) {
      try {
        final url = Uri.parse('http://100.97.64.92:8000/cameras/target/unlock');
        await http.post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'camera_id': widget.patient.deviceId}),
        ).timeout(const Duration(seconds: 3));
        if (mounted) {
          setState(() => _isTargetLocked = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('🔓 Target Unlocked. Returned to free mode.'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      } catch (e) {
        debugPrint('Error unlocking target: $e');
      }
    } else {
      _lockTargetAt(0.5, 0.5);
    }
  }

  @override
  void dispose() {
    _mjpegSubscription?.cancel();
    super.dispose();
  }

  Future<void> _startMjpegStream() async {
    try {
      final token = await _authService.getCurrentUser()?.getIdToken() ?? 'valid-token';
      // IP is set to Laptop Tailscale IP (Permanent & Global)
      final url = Uri.parse('http://100.97.64.92:8000/cameras/${widget.patient.deviceId}/stream?token=$token');
      
      final request = http.Request('GET', url);
      final response = await http.Client().send(request);

      if (response.statusCode != 200) {
        setState(() => _isError = true);
        return;
      }

      List<int> byteBuffer = [];
      _mjpegSubscription = response.stream.listen((List<int> chunk) {
        byteBuffer.addAll(chunk);
        
        int start = -1;
        int end = -1;
        
        for (int i = 0; i < byteBuffer.length - 1; i++) {
          if (byteBuffer[i] == 0xFF && byteBuffer[i+1] == 0xD8) {
            start = i;
          }
          if (byteBuffer[i] == 0xFF && byteBuffer[i+1] == 0xD9) {
            end = i + 1;
            break;
          }
        }
        
        if (start != -1 && end != -1 && start < end) {
          final frameBytes = byteBuffer.sublist(start, end + 1);
          if (mounted) {
            setState(() {
              _latestFrame = Uint8List.fromList(frameBytes);
            });
          }
          byteBuffer = byteBuffer.sublist(end + 1);
        }
      }, onError: (e) {
        if (mounted) setState(() => _isError = true);
      });
    } catch (e) {
      if (mounted) setState(() => _isError = true);
    }
  }

  Color _getEventColor(String type) {
    switch (type.toLowerCase()) {
      case 'fall': return Colors.red;
      case 'restless_movement': return Colors.orange;
      case 'prolonged_stillness': return Colors.blue;
      case 'bed_exit': return Colors.grey;
      default: return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.patient.name} (Rm: ${widget.patient.roomNumber})'),
        actions: [
          IconButton(
            icon: Icon(_isTargetLocked ? Icons.lock_rounded : Icons.track_changes_rounded),
            color: _isTargetLocked ? Colors.greenAccent : Colors.white,
            tooltip: _isTargetLocked ? 'Target Locked (Tap to Unlock)' : 'Lock Patient Target',
            onPressed: _toggleTargetLock,
          ),
        ],
      ),
      body: Column(
        children: [
          // Camera View
          Expanded(
            flex: 2,
            child: Container(
              color: Colors.black,
              width: double.infinity,
              child: _isError
                  ? const Center(
                      child: Text(
                        'Camera Unavailable',
                        style: TextStyle(color: Colors.white, fontSize: 18),
                      ),
                    )
                  : _latestFrame == null
                      ? const Center(child: CircularProgressIndicator())
                      : LayoutBuilder(
                          builder: (context, constraints) {
                            return GestureDetector(
                              onTapUp: (details) {
                                final normX = (details.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0);
                                final normY = (details.localPosition.dy / constraints.maxHeight).clamp(0.0, 1.0);
                                _lockTargetAt(normX, normY);
                              },
                              child: Stack(
                                children: [
                                  Center(
                                    child: Image.memory(
                                      _latestFrame!,
                                      gaplessPlayback: true,
                                      fit: BoxFit.contain,
                                    ),
                                  ),
                                  Positioned(
                                    bottom: 8,
                                    left: 8,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: Colors.black87,
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(
                                          color: _isTargetLocked ? Colors.greenAccent : Colors.white24,
                                          width: 1,
                                        ),
                                      ),
                                      child: Text(
                                        _isTargetLocked
                                            ? '🎯 TARGET LOCKED (Tap to re-target)'
                                            : '💡 Tap patient to lock focus',
                                        style: TextStyle(
                                          color: _isTargetLocked ? Colors.greenAccent : Colors.white70,
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
            ),
          ),
          
          // Recent Events Strip
          Container(
            color: Colors.grey.shade200,
            padding: const EdgeInsets.all(8.0),
            width: double.infinity,
            child: const Text('Recent Events', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ),
          Expanded(
            flex: 1,
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('patient_events')
                  .where('deviceId', isEqualTo: widget.patient.deviceId)
                  .orderBy('timestamp', descending: true)
                  .limit(5)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return const Center(child: Text('No recent events.'));
                }

                final events = snapshot.data!.docs;
                return ListView.builder(
                  itemCount: events.length,
                  itemBuilder: (context, index) {
                    final data = events[index].data() as Map<String, dynamic>;
                    final type = data['eventType'] ?? 'Unknown';
                    final timestamp = data['timestamp'] as Timestamp?;
                    final timeStr = timestamp != null 
                        ? DateFormat('HH:mm:ss').format(timestamp.toDate()) 
                        : '';

                    return ListTile(
                      leading: Icon(Icons.circle, color: _getEventColor(type), size: 12),
                      title: Text(type.replaceAll('_', ' ').toUpperCase()),
                      trailing: Text(timeStr),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
