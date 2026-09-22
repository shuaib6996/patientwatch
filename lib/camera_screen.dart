import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  Timer? _reconnectTimer;
  bool _isDisposed = false;

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
  final String _phoneCameraId = 'mobile_1';
  final http.Client _httpClient = http.Client();
  List<CameraDescription> _availableCameras = [];
  int _selectedCameraIndex = 0;

  // Stream throttle & network flag
  int _lastFrameSendTime = 0;
  bool _isFramePending = false;
  bool get _isTailscaleIp => _serverIp.startsWith('100.');

  // ACK-based flow control for Tailscale:
  // Instead of a fixed timer (which causes queue buildup over high-RTT links),
  // we track whether the server has acknowledged processing the last frame.
  // On WiFi (RTT < 5ms), ACK arrives instantly → same throughput as before.
  // On Tailscale (RTT 50-150ms), we wait for ACK before sending next frame →
  // no queue buildup, always fresh frames, no lag.
  bool _waitingForServerAck = false;
  int _ackTimeoutMs = 0; // If ACK doesn't come within this window, force-unblock
  static const int _tailscaleAckTimeoutMs = 400; // Tailscale: 400ms timeout


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

  void _scheduleReconnect() {
    if (_isDisposed || !mounted) return;
    if (_reconnectTimer != null && _reconnectTimer!.isActive) return;

    _reconnectTimer = Timer(const Duration(seconds: 2), () {
      if (_isDisposed || !mounted) return;
      debugPrint("[WebSocket] Auto-reconnecting to backend ws://$_serverIp:8765...");
      _connectWebSocket();
    });
  }

  void _connectWebSocket() {
    if (_isDisposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    try {
      _channel?.sink.close();
    } catch (_) {}

    try {
      _channel = WebSocketChannel.connect(Uri.parse('ws://$_serverIp:8765'));

      // In phone camera mode, subscribe to 'none' so no video loopback floods the phone
      _sendWsSubscribe(_cameraMode == CameraMode.streamPhone ? 'none' : 'laptop_0');

      _channel!.stream.listen((message) {
        if (!mounted || _isDisposed) return;

        // Cancel any pending reconnect on active connection
        _reconnectTimer?.cancel();
        _reconnectTimer = null;

        try {
          if (message is! String) return;
          final data = jsonDecode(message);
          
          // 1. Two-Way Realtime Camera Synchronization with Dashboard
          final event = data['event'];

          // Server ACK for mobile frame upload — unblocks next frame send
          if (event == 'frame_ack') {
            _waitingForServerAck = false;
            return;
          }

          if (event == 'camera_switched' || event == 'initial_state') {
            final targetCam = (data['camera_id'] ?? data['active_camera_id']) as String?;
            if (targetCam != null) {
              debugPrint("[CameraSync] Syncing camera state: $targetCam");
              if (targetCam.startsWith('mobile') && _cameraMode != CameraMode.streamPhone) {
                _startPhoneCamera();
              } else if (!targetCam.startsWith('mobile') && _cameraMode == CameraMode.streamPhone) {
                _stopPhoneCamera();
              }
            }
            return;
          }
          
          // Handle subscription & waiting events
          if (event != null) {
            debugPrint("WS Event: $event - ${data['camera_id'] ?? data['message'] ?? ''}");
            return;
          }

          // In phone camera mode, ignore backend frames
          if (_cameraMode == CameraMode.streamPhone) return;

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
        if (mounted && !_isDisposed) {
          setState(() {
            _currentStatusMessage = 'Reconnecting to backend...';
            _currentStatusColor = Colors.orange;
          });
          _scheduleReconnect();
        }
      }, onDone: () {
        debugPrint("WebSocket stream closed.");
        if (mounted && !_isDisposed) {
          setState(() {
            _currentStatusMessage = 'Reconnecting to backend...';
            _currentStatusColor = Colors.orange;
          });
          _scheduleReconnect();
        }
      });
    } catch (e) {
      if (mounted && !_isDisposed) {
        setState(() {
          _currentStatusMessage = 'Connecting to backend...';
          _currentStatusColor = Colors.orange;
        });
        _scheduleReconnect();
      }
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

  static const MethodChannel _compressorChannel =
      MethodChannel('com.example.patient_watch/image_compressor');

  /// High-speed native hardware YUV to JPEG compression via Android's libjpeg
  Future<Uint8List?> _compressCameraImageToJpeg(CameraImage image, {int quality = 70}) async {
    try {
      if (image.planes.isEmpty) return null;

      final int width = image.width;
      final int height = image.height;

      if (image.planes.length == 1) {
        // Single NV21 contiguous plane
        final dynamic result = await _compressorChannel.invokeMethod('compressYuvToJpeg', {
          'y': image.planes[0].bytes,
          'width': width,
          'height': height,
          'quality': quality,
        });
        if (result is Uint8List) return result;
        if (result is List<int>) return Uint8List.fromList(result);
        return null;
      } else if (image.planes.length >= 3) {
        // 3 planes YUV_420_888
        final yPlane = image.planes[0];
        final uPlane = image.planes[1];
        final vPlane = image.planes[2];

        final dynamic result = await _compressorChannel.invokeMethod('compressYuvToJpeg', {
          'y': yPlane.bytes,
          'u': uPlane.bytes,
          'v': vPlane.bytes,
          'width': width,
          'height': height,
          'yRowStride': yPlane.bytesPerRow,
          'uvRowStride': uPlane.bytesPerRow,
          'uvPixelStride': uPlane.bytesPerPixel ?? 2,
          'quality': quality,
        });
        if (result is Uint8List) return result;
        if (result is List<int>) return Uint8List.fromList(result);
        return null;
      }
    } catch (e) {
      debugPrint("[Compressor] Native compression error: $e");
    }
    return null;
  }

  Future<void> _flipCamera() async {
    if (_availableCameras.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only one camera available on this device')),
      );
      return;
    }

    try {
      _phoneCameraController?.stopImageStream();
    } catch (_) {}
    try {
      _phoneCameraController?.dispose();
    } catch (_) {}
    _phoneCameraController = null;

    final newIndex = (_selectedCameraIndex + 1) % _availableCameras.length;
    setState(() {
      _selectedCameraIndex = newIndex;
      _currentFrame = null;
    });

    await _initPhoneCamera(_availableCameras[_selectedCameraIndex]);
  }

  Future<void> _initPhoneCamera(CameraDescription camera) async {
    // 1. Dispose existing controller safely
    if (_phoneCameraController != null) {
      try {
        await _phoneCameraController!.stopImageStream();
      } catch (_) {}
      try {
        await _phoneCameraController!.dispose();
      } catch (_) {}
      _phoneCameraController = null;
    }

    final isFront = camera.lensDirection == CameraLensDirection.front;
    setState(() {
      _currentStatusMessage = 'Switching to ${isFront ? "Front" : "Back"} camera...';
      _currentStatusColor = Colors.orange.withValues(alpha: 0.8);
    });

    final controller = CameraController(
      camera,
      ResolutionPreset.medium, // 640x480 — Crystal-clear, high quality monitoring!
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21,
    );

    try {
      await controller.initialize();
      if (!mounted || _isDisposed) {
        controller.dispose();
        return;
      }

      setState(() {
        _phoneCameraController = controller;
        _isStreamingPhone = true;
        _currentStatusMessage = '📱 ${isFront ? "Front" : "Back"} Camera (Live Stream)';
        _currentStatusColor = Colors.teal.withValues(alpha: 0.9);
      });

      // Notify backend + dashboard about camera switch
      _notifyCameraSwitch('mobile_1');
      _sendWsSubscribe('none');

      // Start hardware-accelerated startImageStream (zero camera freeze, zero lag!)
      _startPhoneStream(camera);
    } catch (e) {
      if (mounted && !_isDisposed) {
        setState(() {
          _currentStatusMessage = 'Camera init failed: $e';
          _currentStatusColor = Colors.red;
          _cameraMode = CameraMode.viewBackend;
        });
      }
    }
  }

  /// Notify backend & dashboard about camera source change (syncs both sides)
  Future<void> _notifyCameraSwitch(String cameraId) async {
    try {
      // 1. Send over WebSocket for instant real-time sync across all clients
      _channel?.sink.add(jsonEncode({
        'command': 'switch_camera',
        'camera_id': cameraId,
        'subscribe': cameraId == 'mobile_1' ? 'none' : cameraId,
      }));
      // 2. HTTP POST notification to backend
      _httpClient.post(
        Uri.parse('http://$_serverIp:8000/cameras/notify_switch'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'camera_id': cameraId}),
      ).catchError((_) => http.Response('', 500));
    } catch (_) {}
  }

  /// Hardware-accelerated startImageStream streaming crisp JPEG packets over WebSocket
  void _startPhoneStream(CameraDescription camera) {
    if (_phoneCameraController == null || !_phoneCameraController!.value.isInitialized) return;

    // Timer interval for WiFi fallback throttle
    // WiFi: 15 FPS (65ms). Tailscale: ACK-based (no fixed timer — RTT is the natural throttle).
    const int intervalMs = 65;

    _phoneCameraController!.startImageStream((CameraImage image) async {
      if (!_isStreamingPhone || !mounted || _isDisposed) return;

      final now = DateTime.now().millisecondsSinceEpoch;

      if (_isTailscaleIp) {
        // === ACK-BASED FLOW CONTROL (Tailscale) ===
        // Only send when server acknowledged the last frame, OR timeout expired.
        // This prevents frame queue buildup over high-RTT VPN links.
        if (_isFramePending) return; // Frame being compressed/sent
        if (_waitingForServerAck) {
          // Check if ACK timeout expired (server may have dropped the frame)
          if (now - _lastFrameSendTime < _ackTimeoutMs) return;
          // Timeout expired — unblock and try again
          _waitingForServerAck = false;
        }
      } else {
        // === TIMER-BASED THROTTLE (WiFi) ===
        // WiFi RTT is <5ms so simple timer throttle works perfectly.
        if (now - _lastFrameSendTime < intervalMs || _isFramePending) return;
      }

      _lastFrameSendTime = now;
      _isFramePending = true;
      if (_isTailscaleIp) {
        _waitingForServerAck = true;
        _ackTimeoutMs = _tailscaleAckTimeoutMs;
      }

      try {
        final Uint8List? jpegBytes = await _compressCameraImageToJpeg(image, quality: 70);
        if (jpegBytes == null || !_isStreamingPhone || !mounted || _isDisposed) return;

        // 16-byte binary MOBF header
        final header = ByteData(16);
        header.setUint32(0, 0x4D4F4246); // 'MOBF'
        header.setUint16(4, image.width);
        header.setUint16(6, image.height);
        header.setUint16(8, camera.sensorOrientation);
        header.setUint8(10, _isFrontCamera ? 1 : 0);
        header.setUint8(11, 1); // 1 = JPEG format
        header.setUint32(12, now);

        final packet = Uint8List(16 + jpegBytes.length);
        packet.setRange(0, 16, header.buffer.asUint8List());
        packet.setRange(16, packet.length, jpegBytes);

        // Send directly over persistent WebSocket (zero HTTP overhead, instant!)
        if (_channel != null) {
          _channel!.sink.add(packet);
        } else {
          // Fallback to HTTP POST if WebSocket reconnecting
          _httpClient.post(
            Uri.parse('http://$_serverIp:8000/cameras/mobile/frame?'
                'camera_id=$_phoneCameraId&'
                'sensor_orientation=${camera.sensorOrientation}&'
                'is_front=$_isFrontCamera&'
                'width=${image.width}&'
                'height=${image.height}&'
                'format=jpeg'),
            headers: {'Content-Type': 'application/octet-stream'},
            body: jpegBytes,
          ).catchError((_) => http.Response('', 500));
        }
      } catch (e) {
        debugPrint('[PhoneStream Error] $e');
      } finally {
        _isFramePending = false;
        // Note: _waitingForServerAck remains true until server sends frame_ack.
        // This is intentional — it blocks the next frame send on Tailscale.
      }
    });
  }

  void _stopPhoneCamera() {
    _isStreamingPhone = false;
    _isFramePending = false;
    _waitingForServerAck = false;

    try {
      _phoneCameraController?.stopImageStream();
    } catch (_) {}
    try {
      _phoneCameraController?.dispose();
    } catch (_) {}
    _phoneCameraController = null;

    setState(() {
      _cameraMode = CameraMode.viewBackend;
      _currentStatusMessage = 'Switched back to backend view';
      _currentStatusColor = Colors.green.withValues(alpha: 0.8);
      _currentFrame = null;
    });

    // Notify backend + dashboard about switch back to laptop
    _notifyCameraSwitch('laptop_0');
    _sendWsSubscribe('laptop_0');
  }

  @override
  void dispose() {
    _isDisposed = true;
    _reconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
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
