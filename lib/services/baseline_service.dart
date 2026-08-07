import 'package:flutter/foundation.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

class BaselineService {
  // Configurable thresholds for baseline
  static const Duration calibrationDuration = Duration(minutes: 2); // 2-3 minutes for MVP, can adjust for testing
  
  bool isCalibrating = false;
  DateTime? _calibrationStartTime;
  
  final List<double> _movementVariances = [];
  
  // Stored baselines
  double averageMovementVariance = 0.0;
  double minMovementThreshold = 0.0;
  double maxMovementThreshold = 0.0;

  double? _prevHipY;
  double? _prevHipX;
  double? _prevShoulderY;
  double? _prevShoulderX;

  void startCalibration() {
    isCalibrating = true;
    _calibrationStartTime = DateTime.now();
    _movementVariances.clear();
    debugPrint('Started baseline calibration...');
  }

  void processPoseForCalibration(Pose pose) {
    if (!isCalibrating || pose.landmarks.isEmpty) return;

    final shoulder = pose.landmarks[PoseLandmarkType.leftShoulder];
    final hip = pose.landmarks[PoseLandmarkType.leftHip];

    if (shoulder == null || hip == null) return;

    // Calculate variance (distance moved between frames)
    if (_prevHipX != null && _prevHipY != null && _prevShoulderX != null && _prevShoulderY != null) {
      double dxHip = hip.x - _prevHipX!;
      double dyHip = hip.y - _prevHipY!;
      double hipMovement = (dxHip * dxHip) + (dyHip * dyHip);

      double dxShoulder = shoulder.x - _prevShoulderX!;
      double dyShoulder = shoulder.y - _prevShoulderY!;
      double shoulderMovement = (dxShoulder * dxShoulder) + (dyShoulder * dyShoulder);
      
      _movementVariances.add(hipMovement + shoulderMovement);
    }

    _prevHipX = hip.x;
    _prevHipY = hip.y;
    _prevShoulderX = shoulder.x;
    _prevShoulderY = shoulder.y;

    if (DateTime.now().difference(_calibrationStartTime!) >= calibrationDuration) {
      _finishCalibration();
    }
  }

  void _finishCalibration() {
    isCalibrating = false;
    
    if (_movementVariances.isEmpty) {
      debugPrint('Calibration finished, but no movement tracked. Using default thresholds.');
      averageMovementVariance = 50.0;
      minMovementThreshold = 5.0;
      maxMovementThreshold = 200.0;
      return;
    }

    double sum = _movementVariances.reduce((a, b) => a + b);
    averageMovementVariance = sum / _movementVariances.length;
    
    // Simplistic standard deviation logic for min/max estimation
    _movementVariances.sort();
    
    // E.g., bottom 10% is min, top 90% is max
    int minIndex = (_movementVariances.length * 0.1).floor();
    int maxIndex = (_movementVariances.length * 0.9).floor();
    
    minMovementThreshold = _movementVariances[minIndex];
    maxMovementThreshold = _movementVariances[maxIndex];
    
    // Add some safety padding
    minMovementThreshold = minMovementThreshold * 0.5; // Half of 10th percentile
    maxMovementThreshold = maxMovementThreshold * 3.0; // 3x of 90th percentile

    debugPrint('Calibration Complete:');
    debugPrint('Avg Var: $averageMovementVariance');
    debugPrint('Min Threshold: $minMovementThreshold');
    debugPrint('Max Threshold: $maxMovementThreshold');
  }
}
