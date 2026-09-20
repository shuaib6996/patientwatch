import '../models/pose.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class ActivityClassifier {
  // Configurable thresholds for activity classification
  static const double lyingVerticalThreshold = 40.0;
  static const double walkingHorizontalThreshold = 15.0;

  String currentActivity = "unknown";
  String? _lastLoggedActivityDocId;
  double? _prevHipX;

  Future<void> classifyActivity(Pose pose, String deviceId) async {
    if (pose.landmarks.isEmpty) return;

    final shoulder = pose.landmarks[PoseLandmarkType.leftShoulder];
    final hip = pose.landmarks[PoseLandmarkType.leftHip];
    final knee = pose.landmarks[PoseLandmarkType.leftKnee];

    if (shoulder == null || hip == null || knee == null) return;

    String predictedActivity = "sitting";

    double verticalShoulderHip = (shoulder.y - hip.y).abs();
    double verticalHipKnee = (hip.y - knee.y).abs();

    if (verticalShoulderHip < lyingVerticalThreshold && verticalHipKnee < lyingVerticalThreshold) {
      predictedActivity = "lying";
    } else if (verticalShoulderHip > lyingVerticalThreshold && verticalHipKnee > lyingVerticalThreshold) {
      predictedActivity = "standing";

      if (_prevHipX != null) {
        double dx = (hip.x - _prevHipX!).abs();
        if (dx > walkingHorizontalThreshold) {
          predictedActivity = "walking";
        }
      }
    }

    _prevHipX = hip.x;

    if (currentActivity != predictedActivity) {
      currentActivity = predictedActivity;
      _logActivityTransition(deviceId, currentActivity);
    }
  }

  Future<void> _logActivityTransition(String deviceId, String newActivity) async {
    final now = DateTime.now();

    // End previous activity
    if (_lastLoggedActivityDocId != null) {
      await FirebaseFirestore.instance.collection('activity_log').doc(_lastLoggedActivityDocId).update({
        'endTime': Timestamp.fromDate(now),
      });
    }

    // Start new activity
    final docRef = await FirebaseFirestore.instance.collection('activity_log').add({
      'deviceId': deviceId,
      'activityType': newActivity,
      'startTime': Timestamp.fromDate(now),
      'endTime': null, // null means ongoing
    });

    _lastLoggedActivityDocId = docRef.id;
  }
}
