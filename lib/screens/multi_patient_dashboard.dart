import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/patient.dart';
import '../models/staff.dart';
import '../services/auth_service.dart';
import 'dashboard_screen.dart';
import 'onboarding_screen.dart';
import 'staff_management_screen.dart';

class MultiPatientDashboard extends StatefulWidget {
  const MultiPatientDashboard({Key? key}) : super(key: key);

  @override
  State<MultiPatientDashboard> createState() => _MultiPatientDashboardState();
}

class _MultiPatientDashboardState extends State<MultiPatientDashboard> {
  final AuthService _authService = AuthService();
  Staff? _currentStaff;
  bool _isLoadingStaff = true;

  @override
  void initState() {
    super.initState();
    _loadStaffProfile();
  }

  Future<void> _loadStaffProfile() async {
    final user = _authService.getCurrentUser();
    if (user != null) {
      final doc = await FirebaseFirestore.instance.collection('staff').doc(user.uid).get();
      if (doc.exists) {
        setState(() {
          _currentStaff = Staff.fromMap(doc.data()!, doc.id);
        });
      }
    }
    setState(() {
      _isLoadingStaff = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingStaff) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('All Patients Dashboard'),
        actions: [
          if (_currentStaff?.role == 'admin')
            IconButton(
              icon: const Icon(Icons.admin_panel_settings),
              tooltip: 'Manage Staff & Data',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const StaffManagementScreen()),
                );
              },
            ),
          IconButton(
            icon: const Icon(Icons.person_add),
            tooltip: 'Onboard Patient',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const OnboardingScreen()),
              );
            },
          )
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Profile Section
          if (_currentStaff != null)
            Container(
              padding: const EdgeInsets.all(16),
              color: Colors.blue.shade50,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Logged in as: ${_currentStaff!.name}', style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text('Role: ${_currentStaff!.role.toUpperCase()}'),
                    ],
                  ),
                  TextButton.icon(
                    onPressed: () => _authService.signOut(),
                    icon: const Icon(Icons.logout),
                    label: const Text('Logout'),
                  )
                ],
              ),
            ),
          
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance.collection('patients').where('status', isEqualTo: true).snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return const Center(child: Text('No active patients found. Add one to begin.'));
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
                    return _buildPatientCard(context, patient);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPatientCard(BuildContext context, Patient patient) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: InkWell(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => DashboardScreen(patient: patient),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                patient.name,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text('Room: ${patient.roomNumber} | Bed: ${patient.bedNumber}'),
              const SizedBox(height: 8),
              _buildPatientLiveStatus(patient.deviceId),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPatientLiveStatus(String deviceId) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('patient_events')
          .where('deviceId', isEqualTo: deviceId)
          .orderBy('timestamp', descending: true)
          .limit(1)
          .snapshots(),
      builder: (context, snapshot) {
        String statusText = 'Monitoring (OK)';
        Color statusColor = Colors.green;

        if (snapshot.hasData && snapshot.data!.docs.isNotEmpty) {
          final data = snapshot.data!.docs.first.data() as Map<String, dynamic>;
          final timestamp = data['timestamp'] as Timestamp?;
          final eventType = data['eventType'] as String? ?? 'event';

          if (timestamp != null) {
            final timeDiff = DateTime.now().difference(timestamp.toDate());
            if (timeDiff.inMinutes < 15) {
               statusColor = Colors.red;
               statusText = 'Alert: $eventType';
            }
          }
        }
        return Row(
          children: [
            Icon(Icons.circle, color: statusColor, size: 12),
            const SizedBox(width: 4),
            Text(statusText, style: TextStyle(color: statusColor, fontWeight: FontWeight.bold)),
          ],
        );
      },
    );
  }
}
