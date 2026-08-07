import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'pose_detection_logic.dart';
import 'fall_detection_logic.dart';
import 'firebase_service.dart';
import 'whatsapp_service.dart';
import 'services/baseline_service.dart';
import 'services/stillness_detector.dart';
import 'services/restlessness_detector.dart';
import 'services/activity_classifier.dart';
import 'services/bed_exit_detector.dart';
import 'models/patient.dart';

class CameraScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  final Patient patient;

  const CameraScreen({Key? key, required this.cameras, required this.patient})
      : super(key: key);
  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _cameraController;
  int _cameraIndex = 0;
  bool _isProcessing = false;

  final PoseDetectionLogic _poseDetectionLogic = PoseDetectionLogic();
  final FallDetectionLogic _fallDetectionLogic = FallDetectionLogic();
  final FirebaseService _firebaseService = FirebaseService();
  final WhatsAppService _whatsappService = WhatsAppService();

  final BaselineService _baselineService = BaselineService();
  final StillnessDetector _stillnessDetector = StillnessDetector();
  final RestlessnessDetector _restlessnessDetector = RestlessnessDetector();
  final ActivityClassifier _activityClassifier = ActivityClassifier();
  final BedExitDetector _bedExitDetector = BedExitDetector();

  String _currentStatusMessage = 'Initializing...';
  Color _currentStatusColor = Colors.grey.withValues(alpha: 0.8);
  DateTime? _statusEndTime;
  Pose? _currentPose;
  Size? _imageSize;
  InputImageRotation _rotation = InputImageRotation.rotation90deg;

  @override
  void initState() {
    super.initState();
    if (widget.cameras.isNotEmpty) {
      _initializeCamera(widget.cameras[_cameraIndex]);
    }
    // Start calibration mode immediately
    _baselineService.startCalibration();
    _updateStatusUI();
  }

  void _updateStatusUI() {
    if (mounted) {
      setState(() {
        if (_statusEndTime != null &&
            DateTime.now().isBefore(_statusEndTime!)) {
          // Keep showing the alert status
        } else {
          _statusEndTime = null;
          if (_baselineService.isCalibrating) {
            _currentStatusMessage =
                'Calibrating... please have patient rest normally';
            _currentStatusColor = Colors.orange.withValues(alpha: 0.8);
          } else {
            _currentStatusMessage = 'Monitoring...';
            _currentStatusColor = Colors.green.withValues(alpha: 0.8);
          }
        }
      });
    }
  }

  Future<void> _initializeCamera(CameraDescription camera) async {
    try {
      _cameraController = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await _cameraController?.initialize();
      if (mounted) {
        setState(() {});
        _startImageStream();
      }
    } catch (e) {
      debugPrint("Camera initialization error: $e");
      if (mounted) {
        setState(() {
          _currentStatusMessage =
              'Camera Error: Please allow camera permissions';
          _currentStatusColor = Colors.red.withValues(alpha: 0.8);
        });
      }
    }
  }

  void _startImageStream() {
    _cameraController?.startImageStream((CameraImage image) async {
      if (_isProcessing) return;
      _isProcessing = true;

      try {
        final imageRotation = InputImageRotationValue.fromRawValue(
                widget.cameras[_cameraIndex].sensorOrientation) ??
            InputImageRotation.rotation90deg;
        final Size imageSize =
            Size(image.width.toDouble(), image.height.toDouble());
        final poses = await _poseDetectionLogic.processCameraImage(
          image,
          widget.cameras[_cameraIndex],
        );

        if (poses.isNotEmpty) {
          final pose = poses.first;

          if (_baselineService.isCalibrating) {
            _baselineService.processPoseForCalibration(pose);
          } else {
            // Run continuous activity classification
            await _activityClassifier.classifyActivity(
                pose, widget.patient.deviceId);

            // Check for bed exit
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

          if (mounted) {
            setState(() {
              _currentPose = pose;
              _imageSize = imageSize;
              _rotation = imageRotation;
            });
          }
        } else {
          if (mounted) {
            setState(() {
              _currentPose = null;
            });
          }
        }
      } finally {
        _isProcessing = false;
      }
    });
  }

  Future<void> _handleEventDetected(
      String eventType, String message, Color color) async {
    setState(() {
      _currentStatusMessage = message;
      _currentStatusColor = color;
      _statusEndTime = DateTime.now().add(const Duration(seconds: 5));
    });

    final now = DateTime.now();

    // Log to Firestore
    await _firebaseService.logEvent(widget.patient.deviceId, eventType);

    // Send WhatsApp Alert
    await _whatsappService.sendAlert(eventType, now);

    // Reset UI status after delay
    Future.delayed(const Duration(seconds: 5), () {
      _updateStatusUI();
    });
  }

  Future<void> _toggleCamera() async {
    if (widget.cameras.length > 1) {
      setState(() {
        _isProcessing = true;
      });
      final newIndex = (_cameraIndex + 1) % widget.cameras.length;
      if (_cameraController?.value.isStreamingImages == true) {
        await _cameraController?.stopImageStream();
      }
      await _cameraController?.dispose();
      setState(() {
        _cameraIndex = newIndex;
        _cameraController = null;
        _isProcessing = false;
        _currentPose = null;
      });
      _initializeCamera(widget.cameras[newIndex]);
    }
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _poseDetectionLogic.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('PatientWatch MVP'),
        actions: [
          IconButton(
            icon: const Icon(Icons.cameraswitch),
            onPressed: _toggleCamera,
          )
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Live Camera Preview
          CameraPreview(_cameraController!),

          // Pose Skeleton Overlay
          if (_currentPose != null && _imageSize != null)
            CustomPaint(
              painter: PosePainter(
                _currentPose!,
                imageSize: _imageSize!,
                rotation: _rotation,
                cameraLensDirection: widget.cameras[_cameraIndex].lensDirection,
                blurFaceEnabled: widget.patient.blurFaceEnabled,
                platform: Theme.of(context).platform,
              ),
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

          // Debugging FPS / Status
          Positioned(
            bottom: 20,
            left: 20,
            child: Container(
              padding: const EdgeInsets.all(8),
              color: Colors.black54,
              child: Text(
                _currentPose != null
                    ? 'Pose Tracked'
                    : 'Searching for patient...',
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),

          // Calibration Progress Overlay
          if (_baselineService.isCalibrating)
            Positioned(
              bottom: 60,
              left: 20,
              right: 20,
              child: Container(
                padding: const EdgeInsets.all(12),
                color: Colors.black87,
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.orange),
                    SizedBox(height: 8),
                    Text('Learning baseline movement patterns...',
                        style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            )
        ],
      ),
    );
  }
}

class PosePainter extends CustomPainter {
  final Pose pose;
  final Size imageSize;
  final InputImageRotation rotation;
  final CameraLensDirection cameraLensDirection;
  final bool blurFaceEnabled;
  final TargetPlatform platform;

  PosePainter(
    this.pose, {
    required this.imageSize,
    required this.rotation,
    required this.cameraLensDirection,
    required this.platform,
    this.blurFaceEnabled = false,
  });

  double translateX(double x, Size canvasSize, Size imageSize,
      InputImageRotation rotation, CameraLensDirection cameraLensDirection) {
    switch (rotation) {
      case InputImageRotation.rotation90deg:
        return x *
            canvasSize.width /
            (platform == TargetPlatform.iOS
                ? imageSize.width
                : imageSize.height);
      case InputImageRotation.rotation270deg:
        return canvasSize.width -
            x *
                canvasSize.width /
                (platform == TargetPlatform.iOS
                    ? imageSize.width
                    : imageSize.height);
      case InputImageRotation.rotation0deg:
      case InputImageRotation.rotation180deg:
        switch (cameraLensDirection) {
          case CameraLensDirection.back:
            return x * canvasSize.width / imageSize.width;
          default:
            return canvasSize.width - x * canvasSize.width / imageSize.width;
        }
    }
  }

  double translateY(double y, Size canvasSize, Size imageSize,
      InputImageRotation rotation, CameraLensDirection cameraLensDirection) {
    switch (rotation) {
      case InputImageRotation.rotation90deg:
      case InputImageRotation.rotation270deg:
        return y *
            canvasSize.height /
            (platform == TargetPlatform.iOS
                ? imageSize.height
                : imageSize.width);
      case InputImageRotation.rotation0deg:
      case InputImageRotation.rotation180deg:
        return y * canvasSize.height / imageSize.height;
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.cyanAccent
      ..strokeWidth = 4.0;

    for (final landmark in pose.landmarks.values) {
      final x = translateX(
          landmark.x, size, imageSize, rotation, cameraLensDirection);
      final y = translateY(
          landmark.y, size, imageSize, rotation, cameraLensDirection);
      canvas.drawCircle(Offset(x, y), 5, paint);
    }

    if (blurFaceEnabled) {
      final nose = pose.landmarks[PoseLandmarkType.nose];
      final leftEar = pose.landmarks[PoseLandmarkType.leftEar];
      final rightEar = pose.landmarks[PoseLandmarkType.rightEar];

      if (nose != null) {
        final blurPaint = Paint()
          ..color = Colors.black.withValues(alpha: 0.8)
          ..style = PaintingStyle.fill;

        final noseX =
            translateX(nose.x, size, imageSize, rotation, cameraLensDirection);
        final noseY =
            translateY(nose.y, size, imageSize, rotation, cameraLensDirection);

        double mappedFaceWidth = 100;
        if (leftEar != null && rightEar != null) {
          final leftEarX = translateX(
              leftEar.x, size, imageSize, rotation, cameraLensDirection);
          final rightEarX = translateX(
              rightEar.x, size, imageSize, rotation, cameraLensDirection);
          mappedFaceWidth = (leftEarX - rightEarX).abs() * 2;
          if (mappedFaceWidth < 60) mappedFaceWidth = 100;
        }

        final rect = Rect.fromCenter(
          center: Offset(noseX, noseY),
          width: mappedFaceWidth,
          height: mappedFaceWidth * 1.2,
        );
        canvas.drawRect(rect, blurPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant PosePainter oldDelegate) {
    return true;
  }
}
