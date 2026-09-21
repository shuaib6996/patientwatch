import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'models/pose.dart';
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
  String _serverIp = '100.97.64.92'; // Laptop Tailscale IP (Permanent & Global)
  Timer? _heartbeatTimer;

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
  Timer? _phoneStreamTimer;
  final String _phoneCameraId = 'mobile_1';
  final http.Client _httpClient = http.Client();
  List<CameraDescription> _availableCameras = [];
  int _selectedCameraIndex = 0;

  // === Tailscale Lag Optimization ===
  int _adaptiveFpsMs = 100;        // Start at ~10 FPS, auto-adjust
  int _consecutiveSlowFrames = 0;  // Track slow network responses
  int _consecutiveFastFrames = 0;  // Track fast network responses
  double _avgLatencyMs = 0;        // Running average latency
  int _framesSent = 0;
  int _framesDropped = 0;


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
    _startHeartbeat();
    _connectWebSocket();
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _sendHeartbeat();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 4), (_) => _sendHeartbeat());
  }

  Future<void> _sendHeartbeat() async {
    try {
      final url = Uri.parse('http://$_serverIp:8000/devices/heartbeat');
      await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'device_id': _phoneCameraId,
          'name': widget.patient.name.isNotEmpty
              ? 'Phone - ${widget.patient.name}'
              : 'Android Phone',
          'type': 'mobile_app',
        }),
      ).timeout(const Duration(seconds: 3));
      // Also send websocket keepalive ping
      _channel?.sink.add(jsonEncode({'heartbeat': _phoneCameraId}));
    } catch (e) {
      // Backend may be starting or offline
    }
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
        // In phone camera mode, ignore backend frames (we process locally)
        if (_cameraMode == CameraMode.streamPhone) return;
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
  // Phone Camera Streaming & On-Device Pose Detection
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
    // 1. Stop any previous image stream
    _phoneStreamTimer?.cancel();
    _phoneStreamTimer = null;

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
      ResolutionPreset.low, // 320x240 — lightweight for streaming (fast NV21, small data)
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21,
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
        _currentStatusMessage = '📱 ${isFront ? "Front" : "Back"} Camera (Live Stream)';
        _currentStatusColor = Colors.teal.withValues(alpha: 0.9);
      });

      // Start streaming frames to backend (lightweight & lag-free)
      _startPhoneStream(camera);
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

  void _startPhoneStream(CameraDescription camera) {
    if (_phoneCameraController == null || !_phoneCameraController!.value.isInitialized) return;

    _phoneCameraController!.startImageStream((CameraImage image) {
      if (!_isStreamingPhone || !mounted) return;
      _streamFrameToBackend(image, camera);
    });
  }

  bool _isUploadingFrame = false;
  int _lastFrameUploadTime = 0;

  void _streamFrameToBackend(CameraImage image, CameraDescription camera) async {
    if (_isUploadingFrame || !_isStreamingPhone) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    // Use adaptive FPS interval instead of fixed 100ms
    if (now - _lastFrameUploadTime < _adaptiveFpsMs) return;

    _isUploadingFrame = true;
    _lastFrameUploadTime = now;

    try {
      // Collect raw NV21 bytes — at low res (320x240) this is only ~115KB
      // No Dart-side compression needed; backend OpenCV handles NV21→BGR natively (near-instant C code)
      Uint8List bytes;
      if (image.planes.length == 1) {
        bytes = image.planes[0].bytes;
      } else {
        final WriteBuffer allBytes = WriteBuffer();
        for (final Plane plane in image.planes) {
          allBytes.putUint8List(plane.bytes);
        }
        bytes = allBytes.done().buffer.asUint8List();
      }

      final isFront = camera.lensDirection == CameraLensDirection.front;
      final uri = Uri.parse(
        'http://$_serverIp:8000/cameras/mobile/frame?'
        'camera_id=$_phoneCameraId&'
        'sensor_orientation=${camera.sensorOrientation}&'
        'is_front=$isFront&'
        'width=${image.width}&'
        'height=${image.height}&'
        'format=nv21',
      );

      final stopwatch = Stopwatch()..start();
      await _httpClient.post(
        uri,
        headers: {'Content-Type': 'application/octet-stream'},
        body: bytes,
      ).timeout(const Duration(milliseconds: 2000));
      stopwatch.stop();

      _framesSent++;

      // === Adaptive FPS Logic ===
      final latency = stopwatch.elapsedMilliseconds.toDouble();
      _avgLatencyMs = _avgLatencyMs == 0 ? latency : (_avgLatencyMs * 0.7 + latency * 0.3);

      if (latency > 400) {
        // Network is slow → reduce FPS
        _consecutiveSlowFrames++;
        _consecutiveFastFrames = 0;
        if (_consecutiveSlowFrames >= 3 && _adaptiveFpsMs < 500) {
          _adaptiveFpsMs = (_adaptiveFpsMs * 1.5).round().clamp(100, 500);
          debugPrint('[AdaptiveFPS] Slowing to ${(1000 / _adaptiveFpsMs).toStringAsFixed(1)} FPS (latency: ${latency.round()}ms)');
        }
      } else if (latency < 150) {
        // Network is fast → increase FPS
        _consecutiveFastFrames++;
        _consecutiveSlowFrames = 0;
        if (_consecutiveFastFrames >= 5 && _adaptiveFpsMs > 100) {
          _adaptiveFpsMs = (_adaptiveFpsMs * 0.8).round().clamp(80, 500);
          debugPrint('[AdaptiveFPS] Speeding to ${(1000 / _adaptiveFpsMs).toStringAsFixed(1)} FPS (latency: ${latency.round()}ms)');
        }
      } else {
        _consecutiveSlowFrames = 0;
        _consecutiveFastFrames = 0;
      }
    } catch (_) {
      _framesDropped++;
      // Timeout or network error → aggressively reduce FPS
      if (_adaptiveFpsMs < 400) {
        _adaptiveFpsMs = (_adaptiveFpsMs * 1.8).round().clamp(100, 500);
        debugPrint('[AdaptiveFPS] Network timeout, reducing to ${(1000 / _adaptiveFpsMs).toStringAsFixed(1)} FPS');
      }
    } finally {
      _isUploadingFrame = false;
    }
  }

  void _stopPhoneCamera() {
    _phoneStreamTimer?.cancel();
    _phoneStreamTimer = null;
    _isStreamingPhone = false;

    // Reset adaptive state for next session
    _adaptiveFpsMs = 100;
    _consecutiveSlowFrames = 0;
    _consecutiveFastFrames = 0;
    _avgLatencyMs = 0;
    _framesSent = 0;
    _framesDropped = 0;

    // Stop the image stream before disposing
    try {
      _phoneCameraController?.stopImageStream();
    } catch (_) {}
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
    _heartbeatTimer?.cancel();
    _phoneStreamTimer?.cancel();
    try {
      _phoneCameraController?.stopImageStream();
    } catch (_) {}
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
              const Text("Tailscale IP: 100.97.64.92\nWi-Fi IP: 10.161.120.217\n10.0.2.2 = Emulator", style: TextStyle(fontSize: 12, color: Colors.grey)),
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
                  _serverIp = ipController.text.trim();
                });
                Navigator.pop(context);
                _startHeartbeat();
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
                      // Centered & fitted HD CameraPreview
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
