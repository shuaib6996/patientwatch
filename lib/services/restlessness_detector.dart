import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'baseline_service.dart';

class RestlessnessDetector {
  // Configurable thresholds
  static const Duration restlessnessDurationThreshold = Duration(seconds: 30);
  static const Duration cooldownPeriod = Duration(minutes: 5);

  DateTime? _restlessStartTime;
  DateTime? _lastAlertTime;

  double? _prevHipX;
  double? _prevHipY;

  bool detectRestlessness(Pose pose, BaselineService baselineService) {
    if (baselineService.isCalibrating || pose.landmarks.isEmpty) return false;

    // Check cooldown
    if (_lastAlertTime != null) {
      if (DateTime.now().difference(_lastAlertTime!) < cooldownPeriod) {
        return false;
      }
    }

    final hip = pose.landmarks[PoseLandmarkType.leftHip];
    if (hip == null) return false;

    double movement = 0.0;
    if (_prevHipX != null && _prevHipY != null) {
      double dx = hip.x - _prevHipX!;
      double dy = hip.y - _prevHipY!;
      movement = (dx * dx) + (dy * dy);
    }

    _prevHipX = hip.x;
    _prevHipY = hip.y;

    // A maxMovementThreshold should be calibrated
    if (movement > baselineService.maxMovementThreshold) {
      if (_restlessStartTime == null) {
        _restlessStartTime = DateTime.now();
      } else {
        if (DateTime.now().difference(_restlessStartTime!) >= restlessnessDurationThreshold) {
          _lastAlertTime = DateTime.now();
          _restlessStartTime = null; // Reset
          return true;
        }
      }
    } else {
      // Movement fell below threshold, reset timer
      _restlessStartTime = null;
    }

    return false;
  }
}
