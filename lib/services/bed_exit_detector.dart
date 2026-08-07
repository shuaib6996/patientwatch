import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import '../firebase_service.dart';
import '../whatsapp_service.dart';

class BedExitDetector {
  // Configurable bed zone boundaries (MVP placeholders)
  static const double bedZoneMaxY = 400.0;
  static const double bedZoneMinX = 100.0;
  static const double bedZoneMaxX = 500.0;

  // Alert times (e.g., 11 PM to 6 AM)
  static const int alertStartHour = 23;
  static const int alertEndHour = 6;

  static const Duration cooldownPeriod = Duration(minutes: 5);
  DateTime? _lastAlertTime;

  bool detectBedExit(Pose pose, String currentActivity, String deviceId, FirebaseService firebaseService, WhatsAppService whatsappService) {
    if (pose.landmarks.isEmpty) return false;

    final hip = pose.landmarks[PoseLandmarkType.leftHip];
    if (hip == null) return false;

    bool outsideZone = hip.x < bedZoneMinX || hip.x > bedZoneMaxX || hip.y > bedZoneMaxY;
    bool isUpright = currentActivity == "standing" || currentActivity == "walking";

    if (outsideZone && isUpright) {
      _handleBedExit(deviceId, firebaseService, whatsappService);
      return true;
    }
    return false;
  }

  void _handleBedExit(String deviceId, FirebaseService firebaseService, WhatsAppService whatsappService) {
    final now = DateTime.now();

    if (_lastAlertTime != null && now.difference(_lastAlertTime!) < cooldownPeriod) {
      return;
    }
    _lastAlertTime = now;

    firebaseService.logEvent(deviceId, 'bed_exit');

    if (now.hour >= alertStartHour || now.hour < alertEndHour) {
      whatsappService.sendAlert('bed_exit', now);
    }
  }
}
