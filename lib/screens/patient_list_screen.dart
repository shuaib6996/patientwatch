import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/patient.dart';
import '../models/staff.dart';
import '../services/auth_service.dart';
import 'live_camera_view.dart';
import '../camera_screen.dart';
import '../main.dart';

class PatientListScreen extends StatefulWidget {
  const PatientListScreen({Key? key}) : super(key: key);

  @override
  State<PatientListScreen> createState() => _PatientListScreenState();
}

class _PatientListScreenState extends State<PatientListScreen> {
  final AuthService _authService = AuthService();
  Staff? _currentStaff;
  bool _isLoadingStaff = true;

  @override
  void initState() {
    super.initState();
    _loadStaffProfile();
  }

  Future<void> _loadStaffProfile() async {
    try {
      final user = _authService.getCurrentUser();
      if (user != null) {
        final doc = await FirebaseFirestore.instance.collection('staff').doc(user.uid).get();
        if (doc.exists) {
          setState(() {
            _currentStaff = Staff.fromMap(doc.data()!, doc.id);
          });
        }
      }
    } catch (e) {
      debugPrint("Error loading staff profile: $e");
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingStaff = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingStaff) {
      return const Center(child: CircularProgressIndicator());
    }

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('patients').where('status', isEqualTo: true).snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return const Center(child: Text('No active patients.'));
        }

        List<Patient> patients = snapshot.data!.docs.map((doc) => Patient.fromFirestore(doc)).toList();

        // Role-based filtering
        if (_currentStaff != null && _currentStaff!.role != 'admin' && _currentStaff!.assignedRooms.isNotEmpty) {
          patients = patients.where((p) => _currentStaff!.assignedRooms.contains(p.roomNumber)).toList();
        }

        if (patients.isEmpty) {
          return const Center(child: Text('No patients assigned to your rooms.'));
        }

        return ListView.builder(
          itemCount: patients.length,
          itemBuilder: (context, index) {
            final patient = patients[index];
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: ListTile(
                title: Text(patient.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text('Room: ${patient.roomNumber} | Bed: ${patient.bedNumber}'),
                trailing: ElevatedButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => CameraScreen(cameras: cameras, patient: patient)),
                    );
                  },
                  child: const Text('View Live'),
                ),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => CameraScreen(cameras: cameras, patient: patient)),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}
