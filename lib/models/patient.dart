import 'package:cloud_firestore/cloud_firestore.dart';

class Patient {
  final String patientId;
  final String name; // Or bed number for privacy
  final String roomNumber;
  final String bedNumber;
  final String deviceId;
  final bool status; // true for active, false for inactive
  final DateTime admittedAt;
  final bool blurFaceEnabled;

  Patient({
    required this.patientId,
    required this.name,
    required this.roomNumber,
    required this.bedNumber,
    required this.deviceId,
    required this.status,
    required this.admittedAt,
    this.blurFaceEnabled = false,
  });

  factory Patient.fromFirestore(DocumentSnapshot doc) {
    Map data = doc.data() as Map<String, dynamic>;
    return Patient(
      patientId: doc.id,
      name: data['name'] ?? '',
      roomNumber: data['roomNumber'] ?? '',
      bedNumber: data['bedNumber'] ?? '',
      deviceId: data['deviceId'] ?? '',
      status: data['status'] ?? false,
      admittedAt: (data['admittedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      blurFaceEnabled: data['blurFaceEnabled'] ?? false,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'roomNumber': roomNumber,
      'bedNumber': bedNumber,
      'deviceId': deviceId,
      'status': status,
      'admittedAt': Timestamp.fromDate(admittedAt),
      'blurFaceEnabled': blurFaceEnabled,
    };
  }
}
