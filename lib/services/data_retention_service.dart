import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

class DataRetentionService {
  static const int retentionDays = 30;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<void> cleanupOldEvents() async {
    try {
      DateTime cutoff = DateTime.now().subtract(const Duration(days: retentionDays));
      Timestamp cutoffTimestamp = Timestamp.fromDate(cutoff);

      // Cleanup patient_events
      QuerySnapshot eventsSnapshot = await _firestore
          .collection('patient_events')
          .where('timestamp', isLessThan: cutoffTimestamp)
          .get();

      int deletedEvents = 0;
      for (var doc in eventsSnapshot.docs) {
        await doc.reference.delete();
        deletedEvents++;
      }

      // Cleanup activity_log
      QuerySnapshot activitiesSnapshot = await _firestore
          .collection('activity_log')
          .where('startTime', isLessThan: cutoffTimestamp)
          .get();

      int deletedActivities = 0;
      for (var doc in activitiesSnapshot.docs) {
        await doc.reference.delete();
        deletedActivities++;
      }

      debugPrint('Cleanup complete: Deleted $deletedEvents events and $deletedActivities activities.');
    } catch (e) {
      debugPrint('Error during data cleanup: $e');
    }
  }
}
