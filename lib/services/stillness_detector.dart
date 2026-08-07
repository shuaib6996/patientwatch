import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'baseline_service.dart';

class StillnessDetector {
  // Configurable duration for prolonged stillness
  // Note: 15 minutes in production, but let's use 30 seconds for testing/MVP purposes
  static const Duration stillnessDurationThreshold = Duration(minutes: 15); 
  static const Duration cooldownPeriod = Duration(minutes: 30); // Do not repeatedly alert

  DateTime? _stillnessStartTime;
  DateTime? _lastAlertTime;

  double? _prevHipX;
  double? _prevHipY;
  
  // Example: if (now.hour > 22 || now.hour < 6) return false;

  bool detectStillness(Pose pose, BaselineService baselineService) {
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

    if (movement < baselineService.minMovementThreshold) {
      // Patient is still
      if (_stillnessStartTime == null) {
        _stillnessStartTime = DateTime.now();
      } else {
        if (DateTime.now().difference(_stillnessStartTime!) >= stillnessDurationThreshold) {
          _lastAlertTime = DateTime.now();
          _stillnessStartTime = null; // Reset for next detection
          return true;
        }
      }
    } else {
      // Patient moved above min threshold, reset stillness timer
      _stillnessStartTime = null;
    }

    return false;
  }
}
