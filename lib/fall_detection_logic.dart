import 'models/pose.dart';

class FallDetectionLogic {
  /// CONFIGURABLE THRESHOLDS for Fall Detection
  
  // 1. Velocity Threshold: Defines how fast the hip drops vertically (pixels/second).
  // A higher value requires a faster fall to trigger an alert.
  static const double velocityThreshold = 1500.0; 
  
  // 2. Angle Threshold: The ratio of horizontal width to vertical height.
  // If the body width (dx) is significantly greater than height (dy), the person is likely lying down.
  static const double horizontalRatioThreshold = 1.2; 
  
  // 3. Cooldown Period: Prevents spamming alerts for the same fall event.
  static const Duration cooldownPeriod = Duration(seconds: 30);

  DateTime? _lastFallDetectedAt;
  
  // Tracking previous frames to calculate velocity
  double? _prevHipY;
  DateTime? _prevFrameTime;

  bool detectFall(Pose pose) {
    if (pose.landmarks.isEmpty) return false;

    // Check cooldown to avoid duplicate alerts
    if (_lastFallDetectedAt != null) {
      if (DateTime.now().difference(_lastFallDetectedAt!) < cooldownPeriod) {
        return false;
      }
    }

    // Extract landmarks (using left side as proxy, could be averaged with right side)
    final shoulder = pose.landmarks[PoseLandmarkType.leftShoulder];
    final hip = pose.landmarks[PoseLandmarkType.leftHip];
    final knee = pose.landmarks[PoseLandmarkType.leftKnee];

    if (shoulder == null || hip == null || knee == null) return false;

    final now = DateTime.now();
    bool isRapidDrop = false;
    bool isHorizontal = false;

    // 1. Velocity-based logic (Rapid vertical drop of the hip)
    if (_prevHipY != null && _prevFrameTime != null) {
      final dt = now.difference(_prevFrameTime!).inMilliseconds / 1000.0; // Seconds elapsed
      if (dt > 0) {
        final velocity = (hip.y - _prevHipY!) / dt; 
        // Positive velocity means moving downward on the screen
        if (velocity > velocityThreshold) {
           isRapidDrop = true;
        }
      }
    }
    
    // 2. Orientation-based logic (Shoulder-to-Hip horizontal vs vertical distance)
    final dx = (hip.x - shoulder.x).abs();
    final dy = (hip.y - shoulder.y).abs();
    
    if (dy > 0 && (dx / dy) > horizontalRatioThreshold) {
      isHorizontal = true; 
    }

    // Update state for next frame
    _prevHipY = hip.y;
    _prevFrameTime = now;

    // A fall is detected if either they rapidly drop OR their body orientation becomes horizontal
    if (isRapidDrop || isHorizontal) {
       _lastFallDetectedAt = now;
       return true;
    }

    return false;
  }
}
