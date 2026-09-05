import 'dart:async';
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

  @override
  void initState() {
    super.initState();
    _startMjpegStream();
  }

  @override
  void dispose() {
    _mjpegSubscription?.cancel();
    super.dispose();
  }

  Future<void> _startMjpegStream() async {
    try {
      final token = await _authService.getCurrentUser()?.getIdToken() ?? 'valid-token';
      // IP is hardcoded for emulator accessing host. In production, use saved IP.
      final url = Uri.parse('http://10.0.2.2:8000/cameras/${widget.patient.deviceId}/stream?token=$token');
      
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
                      : Image.memory(
                          _latestFrame!,
                          gaplessPlayback: true,
                          fit: BoxFit.contain,
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
