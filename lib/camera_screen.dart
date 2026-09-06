import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'fall_detection_logic.dart';
import 'gesture_detection_logic.dart';
import 'firebase_service.dart';
import 'whatsapp_service.dart';
import 'services/baseline_service.dart';
import 'services/stillness_detector.dart';
import 'services/restlessness_detector.dart';
import 'services/activity_classifier.dart';
import 'services/bed_exit_detector.dart';
import 'models/patient.dart';

class CameraScreen extends StatefulWidget {
  final List<CameraDescription> cameras; // Kept for signature compatibility
  final Patient patient;

  const CameraScreen({Key? key, required this.cameras, required this.patient})
      : super(key: key);
  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  WebSocketChannel? _channel;
  Uint8List? _currentFrame;
  String _serverIp = '10.0.2.2'; // Default for Android Emulator. Use 127.0.0.1 for Windows Desktop.

  final FallDetectionLogic _fallDetectionLogic = FallDetectionLogic();
  final GestureDetectionLogic _gestureDetectionLogic = GestureDetectionLogic();
  final FirebaseService _firebaseService = FirebaseService();
  final WhatsAppService _whatsappService = WhatsAppService();

  final BaselineService _baselineService = BaselineService();
  final StillnessDetector _stillnessDetector = StillnessDetector();
  final RestlessnessDetector _restlessnessDetector = RestlessnessDetector();
  final ActivityClassifier _activityClassifier = ActivityClassifier();
  final BedExitDetector _bedExitDetector = BedExitDetector();

  String _currentStatusMessage = 'Connecting to PC Backend...';
  Color _currentStatusColor = Colors.grey.withValues(alpha: 0.8);
  DateTime? _statusEndTime;

  @override
  void initState() {
    super.initState();
    _baselineService.startCalibration();
    _updateStatusUI();
    _connectWebSocket();
  }

  void _connectWebSocket() {
    _channel?.sink.close(); // Close existing if any
    try {
      _channel = WebSocketChannel.connect(Uri.parse('ws://$_serverIp:8765'));
      _channel!.stream.listen((message) {
        if (!mounted) return;
        try {
          final data = jsonDecode(message);
          
          final base64Image = data['frame'] as String;
          final imageBytes = base64Decode(base64Image);
          
          final poseData = data['pose'] as List<dynamic>;
          
          Pose? pose;
          if (poseData.isNotEmpty) {
            pose = _parsePose(poseData);
          }
          
          _processAnalyzedData(pose);
          
          setState(() {
            _currentFrame = imageBytes;
            _currentStatusMessage = _baselineService.isCalibrating 
                ? 'Calibrating...' 
                : 'Monitoring...';
            _currentStatusColor = Colors.green.withValues(alpha: 0.8);
          });
        } catch (e) {
          debugPrint("Error parsing websocket data: $e");
        }
      }, onError: (e) {
        debugPrint("WebSocket Error: $e");
        if (mounted) {
          setState(() {
            _currentStatusMessage = 'Backend Disconnected. Run main.py';
            _currentStatusColor = Colors.red;
          });
        }
      }, onDone: () {
        if (mounted) {
          setState(() {
            _currentStatusMessage = 'Backend Disconnected.';
            _currentStatusColor = Colors.red;
          });
        }
      });
    } catch (e) {
      setState(() {
        _currentStatusMessage = 'Failed to connect. Run python backend.';
        _currentStatusColor = Colors.red;
      });
    }
  }

  Pose _parsePose(List<dynamic> poseData) {
    final Map<PoseLandmarkType, PoseLandmark> landmarks = {};
    for (int i = 0; i < poseData.length && i < PoseLandmarkType.values.length; i++) {
      final pt = poseData[i];
      final type = PoseLandmarkType.values[i];
      landmarks[type] = PoseLandmark(
        type: type,
        x: (pt['x'] as num).toDouble(),
        y: (pt['y'] as num).toDouble(),
        z: (pt['z'] as num).toDouble(),
        likelihood: (pt['visibility'] as num).toDouble(),
      );
    }
    return Pose(landmarks: landmarks);
  }

  Future<void> _processAnalyzedData(Pose? pose) async {
    if (pose == null) return;

    if (_baselineService.isCalibrating) {
      _baselineService.processPoseForCalibration(pose);
    } else {
      await _activityClassifier.classifyActivity(pose, widget.patient.deviceId);

      // Check Level 1 Active Gestures (Calling Doctor, Washroom, Water, Blanket, Chest Pain)
      final gestureResult = _gestureDetectionLogic.detectGesture(pose);
      if (gestureResult.gesture != DetectedGesture.none) {
        Color gestureColor = Colors.orange;
        if (gestureResult.gesture == DetectedGesture.emergencyHelpWave) {
          gestureColor = Colors.red;
        } else if (gestureResult.gesture == DetectedGesture.waterRequest) {
          gestureColor = Colors.blue;
        } else if (gestureResult.gesture == DetectedGesture.washroomRequest) {
          gestureColor = Colors.amber.shade800;
        } else if (gestureResult.gesture == DetectedGesture.blanketRequest) {
          gestureColor = Colors.teal;
        } else if (gestureResult.gesture == DetectedGesture.chestPainDistress) {
          gestureColor = Colors.deepOrange;
        }

        _handleEventDetected(
          gestureResult.eventType,
          gestureResult.displayTitle,
          gestureColor.withValues(alpha: 0.95),
        );
      }

      final isBedExit = _bedExitDetector.detectBedExit(
          pose,
          _activityClassifier.currentActivity,
          widget.patient.deviceId,
          _firebaseService,
          _whatsappService);

      if (isBedExit) {
        _handleEventDetected('bed_exit', '⚠️ BED EXIT DETECTED',
            Colors.orange.withValues(alpha: 0.9));
      }

      final isFall = _fallDetectionLogic.detectFall(pose);

      if (isFall) {
        _handleEventDetected('fall', '⚠️ FALL DETECTED - Alert Sent',
            Colors.red.withValues(alpha: 0.9));
      } else {
        final isRestless = _restlessnessDetector.detectRestlessness(
            pose, _baselineService);
        if (isRestless) {
          _handleEventDetected(
              'restless_movement',
              '⚠️ RESTLESS MOVEMENT DETECTED',
              Colors.purple.withValues(alpha: 0.9));
        } else {
          final isStill =
              _stillnessDetector.detectStillness(pose, _baselineService);
          if (isStill) {
            _handleEventDetected(
                'prolonged_stillness',
                '⚠️ PROLONGED STILLNESS DETECTED',
                Colors.blue.withValues(alpha: 0.9));
          }
        }
      }
    }
    _updateStatusUI();
  }

  void _updateStatusUI() {
    if (mounted) {
      setState(() {
        if (_statusEndTime != null &&
            DateTime.now().isBefore(_statusEndTime!)) {
          // Keep showing alert
        } else {
          _statusEndTime = null;
        }
      });
    }
  }

  Future<void> _handleEventDetected(
      String eventType, String message, Color color) async {
    setState(() {
      _currentStatusMessage = message;
      _currentStatusColor = color;
      _statusEndTime = DateTime.now().add(const Duration(seconds: 5));
    });

    final now = DateTime.now();
    await _firebaseService.logEvent(widget.patient.deviceId, eventType);
    await _whatsappService.sendAlert(eventType, now);
  }

  @override
  void dispose() {
    _channel?.sink.close();
    super.dispose();
  }

  void _showIpDialog() {
    TextEditingController ipController = TextEditingController(text: _serverIp);
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("Set Backend IP Address"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ipController,
                decoration: const InputDecoration(labelText: "IP Address"),
              ),
              const SizedBox(height: 8),
              const Text("10.0.2.2 = Android Emulator\n127.0.0.1 = Windows Desktop\n192.168.x.x = Real Phone on WiFi", style: TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _serverIp = ipController.text;
                });
                Navigator.pop(context);
                _connectWebSocket();
              },
              child: const Text("Connect"),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PatientWatch - PC Backend'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Change IP Address',
            onPressed: _showIpDialog,
          )
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Live Video Feed from Python
          if (_currentFrame != null)
            Image.memory(
              _currentFrame!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            )
          else
            const Center(
              child: Text("Waiting for Python Backend... (Run main.py)"),
            ),

          // Status Indicator
          Positioned(
            top: 20,
            left: 20,
            right: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              decoration: BoxDecoration(
                color: _currentStatusColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _currentStatusMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
