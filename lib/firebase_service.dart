import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

class FirebaseService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<void> logEvent(String deviceId, String eventType) async {
    try {
      await _firestore.collection('patient_events').add({
        'timestamp': FieldValue.serverTimestamp(),
        'deviceId': deviceId,
        'eventType': eventType, // 'fall', 'prolonged_stillness', 'restless_movement'
        'status': 'detected',
        'note': 'Automatically detected by PatientWatch MVP',
      });
      debugPrint('Successfully logged $eventType event to Firestore');
    } catch (e) {
      debugPrint('Error logging $eventType event: $e');
      // Graceful error handling - log locally but don't crash the app
    }
  }
}
