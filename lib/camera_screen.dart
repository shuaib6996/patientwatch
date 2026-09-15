import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:http/http.dart' as http;
import 'dart:async';
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

enum CameraMode { viewBackend, streamPhone }

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
  String _serverIp = '10.138.52.217'; // Hotspot "On the spot" IP

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

  // ---- Multi-Camera & Flip Mode ----
  CameraMode _cameraMode = CameraMode.viewBackend;
  CameraController? _phoneCameraController;
  bool _isStreamingPhone = false;
  bool _isCapturingFrame = false;
  Timer? _phoneStreamTimer;
  final String _phoneCameraId = 'mobile_1';
  final http.Client _httpClient = http.Client();
  List<CameraDescription> _availableCameras = [];
  int _selectedCameraIndex = 0;

  bool get _isFrontCamera {
    if (_availableCameras.isEmpty || _selectedCameraIndex >= _availableCameras.length) {
      return false;
    }
    return _availableCameras[_selectedCameraIndex].lensDirection == CameraLensDirection.front;
  }

  @override
  void initState() {
    super.initState();
    _availableCameras = widget.cameras;
    if (_availableCameras.isEmpty) {
      availableCameras().then((cams) {
        if (mounted) {
          setState(() {
            _availableCameras = cams;
          });
        }
      });
    }
    _baselineService.startCalibration();
    _updateStatusUI();
    _connectWebSocket();
  }

  void _sendWsSubscribe(String cameraId) {
    try {
      if (_channel != null) {
        _channel!.sink.add(jsonEncode({'subscribe': cameraId}));
        debugPrint("Sent WS subscribe for: $cameraId");
      }
    } catch (e) {
      debugPrint("Error sending WS subscribe: $e");
    }
  }

  void _connectWebSocket() {
    _channel?.sink.close(); // Close existing if any
    try {
      _channel = WebSocketChannel.connect(Uri.parse('ws://$_serverIp:8765'));
      _sendWsSubscribe(_cameraMode == CameraMode.streamPhone ? _phoneCameraId : 'laptop_0');
      _channel!.stream.listen((message) {
        if (!mounted) return;
        try {
          final data = jsonDecode(message);
          
          // Handle subscription events
          if (data['event'] != null) {
            debugPrint("WS Event: ${data['event']} - ${data['camera_id'] ?? data['message'] ?? ''}");
            return;
          }

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
      final double x = pt['norm_x'] != null
          ? (pt['norm_x'] as num).toDouble()
          : (pt['x'] as num).toDouble();
      final double y = pt['norm_y'] != null
          ? (pt['norm_y'] as num).toDouble()
          : (pt['y'] as num).toDouble();

      landmarks[type] = PoseLandmark(
        type: type,
        x: x,
        y: y,
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

  // ============================================================
  // Phone Camera Streaming & Flip
  // ============================================================

  Future<void> _startPhoneCamera() async {
    if (_availableCameras.isEmpty) {
      _availableCameras = await availableCameras();
    }
    if (!mounted) return;
    if (_availableCameras.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No camera available on this device')),
      );
      return;
    }

    setState(() {
      _cameraMode = CameraMode.streamPhone;
      _currentStatusMessage = 'Starting phone camera...';
      _currentStatusColor = Colors.orange.withValues(alpha: 0.8);
    });

    // Subscribe WebSocket to mobile_1 stream so we receive processed MediaPipe frames!
    _sendWsSubscribe(_phoneCameraId);

    // Initialize with currently selected camera
    if (_selectedCameraIndex >= _availableCameras.length) {
      _selectedCameraIndex = 0;
    }
    await _initPhoneCamera(_availableCameras[_selectedCameraIndex]);
  }

  Future<void> _flipCamera() async {
    if (_availableCameras.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only one camera available on this device')),
      );
      return;
    }

    final newIndex = (_selectedCameraIndex + 1) % _availableCameras.length;
    setState(() {
      _selectedCameraIndex = newIndex;
      _currentFrame = null;
    });

    await _initPhoneCamera(_availableCameras[_selectedCameraIndex]);
  }

  Future<void> _initPhoneCamera(CameraDescription camera) async {
    // 1. Pause existing stream timer
    _phoneStreamTimer?.cancel();
    _phoneStreamTimer = null;
    _isCapturingFrame = false;

    // 2. Dispose existing controller
    if (_phoneCameraController != null) {
      await _phoneCameraController!.dispose();
      _phoneCameraController = null;
    }

    final isFront = camera.lensDirection == CameraLensDirection.front;
    setState(() {
      _currentStatusMessage = 'Switching to ${isFront ? "Front" : "Back"} camera...';
      _currentStatusColor = Colors.orange.withValues(alpha: 0.8);
    });

    final controller = CameraController(
      camera,
      ResolutionPreset.high, // Crystal-clear 720p HD resolution
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await controller.initialize();
      if (!mounted) {
        controller.dispose();
        return;
      }

      setState(() {
        _phoneCameraController = controller;
        _isStreamingPhone = true;
        _currentStatusMessage = '📱 ${isFront ? "Front" : "Back"} Camera Active (MediaPipe)';
        _currentStatusColor = Colors.teal.withValues(alpha: 0.9);
      });

      _startFrameCapture();
    } catch (e) {
      if (mounted) {
        setState(() {
          _currentStatusMessage = 'Camera init failed: $e';
          _currentStatusColor = Colors.red;
          _cameraMode = CameraMode.viewBackend;
        });
      }
    }
  }

  void _startFrameCapture() {
    _phoneStreamTimer?.cancel();
    // 250ms = 4 FPS — relaxed capture, zero shutter freeze on camera preview
    _phoneStreamTimer = Timer.periodic(const Duration(milliseconds: 250), (_) async {
      if (!_isStreamingPhone || _phoneCameraController == null || !_phoneCameraController!.value.isInitialized) {
        return;
      }
      if (_isCapturingFrame) return; // Prevent concurrent takePicture calls
      _isCapturingFrame = true;

      try {
        final XFile photo = await _phoneCameraController!.takePicture();
        final bytes = await photo.readAsBytes();

        final isFront = _isFrontCamera;
        final sensorOrientation = _availableCameras.isNotEmpty && _selectedCameraIndex < _availableCameras.length
            ? _availableCameras[_selectedCameraIndex].sensorOrientation
            : 90;

        final url = Uri.parse(
            'http://$_serverIp:8000/cameras/mobile/frame?camera_id=$_phoneCameraId&sensor_orientation=$sensorOrientation&is_front=$isFront');
        await _httpClient.post(
          url,
          body: bytes,
          headers: {'Content-Type': 'application/octet-stream'},
        );
      } catch (e) {
        // Silently continue - frame drops are expected
      } finally {
        _isCapturingFrame = false;
      }
    });
  }

  void _stopPhoneCamera() {
    _phoneStreamTimer?.cancel();
    _phoneStreamTimer = null;
    _isStreamingPhone = false;
    _isCapturingFrame = false;
    _phoneCameraController?.dispose();
    _phoneCameraController = null;

    setState(() {
      _cameraMode = CameraMode.viewBackend;
      _currentStatusMessage = 'Switched back to backend view';
      _currentStatusColor = Colors.green.withValues(alpha: 0.8);
      _currentFrame = null;
    });

    // Re-subscribe WebSocket to laptop webcam
    _sendWsSubscribe('laptop_0');
  }

  @override
  void dispose() {
    _phoneStreamTimer?.cancel();
    _phoneCameraController?.dispose();
    _httpClient.close();
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
        title: const Text('PatientWatch - Multi-Camera'),
        actions: [
          // Flip Camera Button (Visible when Phone Camera is active)
          if (_cameraMode == CameraMode.streamPhone)
            IconButton(
              icon: const Icon(Icons.flip_camera_android),
              tooltip: 'Flip Camera (Front/Back)',
              onPressed: _flipCamera,
            ),
          // Camera Mode Toggle
          IconButton(
            icon: Icon(
              _cameraMode == CameraMode.viewBackend 
                  ? Icons.phone_android 
                  : Icons.desktop_windows,
            ),
            tooltip: _cameraMode == CameraMode.viewBackend
                ? 'Switch to Phone Camera'
                : 'Switch to Backend View',
            onPressed: () {
              if (_cameraMode == CameraMode.viewBackend) {
                _startPhoneCamera();
              } else {
                _stopPhoneCamera();
              }
            },
          ),
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
          // Video Feed
          if (_cameraMode == CameraMode.streamPhone) ...[
            if (_phoneCameraController != null && _phoneCameraController!.value.isInitialized)
              LayoutBuilder(
                builder: (context, constraints) {
                  final double screenW = constraints.maxWidth;
                  final double screenH = constraints.maxHeight;
                  // In portrait mode, camera aspect ratio is height/width (inverted)
                  double rawAspect = _phoneCameraController!.value.aspectRatio;
                  double cameraAspect = rawAspect > 1.0 ? (1.0 / rawAspect) : rawAspect;

                  double previewW, previewH;
                  if (screenW / screenH > cameraAspect) {
                    previewW = screenW;
                    previewH = screenW / cameraAspect;
                  } else {
                    previewH = screenH;
                    previewW = screenH * cameraAspect;
                  }
                  final double dx = (screenW - previewW) / 2.0;
                  final double dy = (screenH - previewH) / 2.0;

                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      // Centered & fitted HD CameraPreview without skeleton overlay
                      Positioned(
                        left: dx,
                        top: dy,
                        width: previewW,
                        height: previewH,
                        child: CameraPreview(_phoneCameraController!),
                      ),
                    ],
                  );
                },
              )
            else
              const Center(child: CircularProgressIndicator()),
          ] else if (_cameraMode == CameraMode.viewBackend) ...[
            // Backend camera feed (laptop webcam / CCTV / mobile with MediaPipe skeleton)
            if (_currentFrame != null)
              Image.memory(
                _currentFrame!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              )
            else
              const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text("Waiting for backend camera feed..."),
                  ],
                ),
              ),
          ],

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

          // Camera Mode Badge (Bottom Left)
          Positioned(
            bottom: 20,
            left: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
              decoration: BoxDecoration(
                color: _cameraMode == CameraMode.streamPhone
                    ? Colors.teal.withValues(alpha: 0.9)
                    : Colors.blueGrey.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _cameraMode == CameraMode.streamPhone
                        ? Icons.phone_android
                        : Icons.desktop_windows,
                    color: Colors.white,
                    size: 18,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _cameraMode == CameraMode.streamPhone
                        ? '📱 Phone (${_isFrontCamera ? "Front" : "Back"})'
                        : '🖥️ Backend Camera',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Flip Camera Floating Button (Bottom Right, Phone Mode only)
          if (_cameraMode == CameraMode.streamPhone)
            Positioned(
              bottom: 20,
              right: 20,
              child: FloatingActionButton(
                heroTag: 'flip_camera_btn',
                backgroundColor: Colors.black.withValues(alpha: 0.65),
                tooltip: 'Flip Camera (Front/Back)',
                onPressed: _flipCamera,
                child: const Icon(
                  Icons.flip_camera_android,
                  color: Colors.white,
                  size: 26,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
