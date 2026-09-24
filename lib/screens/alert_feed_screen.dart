import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../models/patient.dart';
import '../models/staff.dart';
import '../services/auth_service.dart';
import 'live_camera_view.dart';

class AlertFeedScreen extends StatefulWidget {
  const AlertFeedScreen({Key? key}) : super(key: key);

  @override
  State<AlertFeedScreen> createState() => _AlertFeedScreenState();
}

class _AlertFeedScreenState extends State<AlertFeedScreen> {
  final AuthService _authService = AuthService();
  Staff? _currentStaff;
  bool _isLoadingStaff = true;
  List<Patient> _allPatients = [];

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    try {
      final user = _authService.getCurrentUser();
      if (user != null) {
        final doc = await FirebaseFirestore.instance
            .collection('staff')
            .doc(user.uid)
            .get();
        if (doc.exists) {
          _currentStaff = Staff.fromMap(doc.data()!, doc.id);
        }
      }

      // Pre-load patients for fast lookups
      final patientsSnap =
          await FirebaseFirestore.instance.collection('patients').get();
      _allPatients =
          patientsSnap.docs.map((d) => Patient.fromFirestore(d)).toList();
    } catch (e) {
      debugPrint("Error loading initial data: $e");
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingStaff = false;
        });
      }
    }
  }

  Patient? _getPatientByDeviceId(String deviceId) {
    try {
      return _allPatients.firstWhere((p) => p.deviceId == deviceId);
    } catch (e) {
      return null;
    }
  }

  Color _getEventColor(String type) {
    switch (type.toLowerCase()) {
      case 'fall':
      case 'emergency_help_wave':
        return Colors.red;
      case 'chest_pain_distress':
        return Colors.deepOrange;
      case 'washroom_request':
        return Colors.amber.shade800;
      case 'water_request':
        return Colors.blue;
      case 'blanket_request':
        return Colors.teal;
      case 'bed_exit':
        return Colors.orange;
      case 'restless_movement':
        return Colors.purple;
      case 'prolonged_stillness':
        return Colors.indigo;
      default:
        return Colors.blueGrey;
    }
  }

  IconData _getEventIcon(String type) {
    switch (type.toLowerCase()) {
      case 'fall':
        return Icons.warning_rounded;
      case 'emergency_help_wave':
        return Icons.waving_hand;
      case 'chest_pain_distress':
        return Icons.healing;
      case 'washroom_request':
        return Icons.wc;
      case 'water_request':
        return Icons.local_drink;
      case 'blanket_request':
        return Icons.airline_seat_individual_suite;
      case 'bed_exit':
        return Icons.exit_to_app;
      case 'restless_movement':
        return Icons.directions_run;
      case 'prolonged_stillness':
        return Icons.bedtime;
      default:
        return Icons.notifications_active;
    }
  }

  String _formatEventLabel(String type) {
    switch (type.toLowerCase()) {
      case 'emergency_help_wave':
        return '🚨 URGENT: Calling Doctor / Help';
      case 'washroom_request':
        return '🚻 Washroom / Toilet Assistance';
      case 'water_request':
        return '💧 Water / Thirst Assistance';
      case 'blanket_request':
        return '🛌 Blanket / Cold Comfort';
      case 'chest_pain_distress':
        return '⚠️ Chest Pain Distress Reported';
      case 'fall':
        return '⚠️ Fall Detected';
      case 'bed_exit':
        return '⚠️ Bed Exit Attempt';
      case 'restless_movement':
        return 'Restless Movement';
      case 'prolonged_stillness':
        return 'Prolonged Stillness';
      default:
        return type.replaceAll('_', ' ').toUpperCase();
    }
  }

  Future<void> _confirmDeleteAlert(
      BuildContext context, DocumentReference ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Alert'),
        content:
            const Text('Are you sure you want to delete this notification?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (shouldDelete == true) {
      try {
        await ref.delete();
        messenger.showSnackBar(
          const SnackBar(content: Text('Alert deleted successfully.')),
        );
      } catch (e) {
        messenger.showSnackBar(
          SnackBar(content: Text('Failed to delete alert: $e')),
        );
      }
    }
  }

  Future<void> _confirmClearAllAlerts(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final shouldClear = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear All Alerts'),
        content: const Text(
            'Are you sure you want to delete ALL alert notifications? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child:
                const Text('Delete All', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (shouldClear == true) {
      try {
        final snap =
            await FirebaseFirestore.instance.collection('patient_events').get();
        final batch = FirebaseFirestore.instance.batch();
        for (final doc in snap.docs) {
          batch.delete(doc.reference);
        }
        await batch.commit();
        messenger.showSnackBar(
          const SnackBar(content: Text('All alerts deleted successfully.')),
        );
      } catch (e) {
        messenger.showSnackBar(
          SnackBar(content: Text('Failed to clear alerts: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingStaff) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
          color: Colors.grey.shade200,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.circle, color: Colors.green, size: 10),
                  SizedBox(width: 6),
                  Text('Live Alert Feed',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                ],
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: Colors.red,
                  visualDensity: VisualDensity.compact,
                ),
                icon: const Icon(Icons.delete_sweep, size: 18),
                label: const Text('Clear All',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                onPressed: () => _confirmClearAllAlerts(context),
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('patient_events')
                .orderBy('timestamp', descending: true)
                .limit(100)
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                return const Center(child: Text('No recent alerts.'));
              }

              var events = snapshot.data!.docs;

              // Role-based filtering
              if (_currentStaff != null &&
                  _currentStaff!.role != 'admin' &&
                  _currentStaff!.assignedRooms.isNotEmpty) {
                events = events.where((doc) {
                  final data = doc.data() as Map<String, dynamic>;
                  final p = _getPatientByDeviceId(data['deviceId'] ?? '');
                  if (p == null) return false;
                  return _currentStaff!.assignedRooms.contains(p.roomNumber);
                }).toList();
              }

              if (events.isEmpty) {
                return const Center(
                    child: Text('No alerts for your assigned rooms.'));
              }

              return ListView.builder(
                itemCount: events.length,
                itemBuilder: (context, index) {
                  final data = events[index].data() as Map<String, dynamic>;
                  final type = data['eventType'] ?? 'Unknown';
                  final deviceId = data['deviceId'] ?? '';
                  final timestamp = data['timestamp'] as Timestamp?;

                  final patient = _getPatientByDeviceId(deviceId);
                  final title = patient != null
                      ? '${patient.name} (Rm: ${patient.roomNumber})'
                      : 'Unknown Patient ($deviceId)';

                  final timeStr = timestamp != null
                      ? DateFormat('HH:mm:ss').format(timestamp.toDate())
                      : '';

                  return Card(
                    margin:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor:
                            _getEventColor(type).withValues(alpha: 0.2),
                        child: Icon(_getEventIcon(type),
                            color: _getEventColor(type)),
                      ),
                      title: Text(title,
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text(_formatEventLabel(type),
                          style: TextStyle(
                              color: _getEventColor(type),
                              fontWeight: FontWeight.w600)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(timeStr,
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.grey)),
                          const SizedBox(width: 4),
                          IconButton(
                            icon: const Icon(Icons.delete_outline,
                                color: Colors.red, size: 22),
                            tooltip: 'Delete Alert',
                            onPressed: () => _confirmDeleteAlert(
                                context, events[index].reference),
                          ),
                        ],
                      ),
                      onTap: () {
                        if (patient != null) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (context) =>
                                    LiveCameraView(patient: patient)),
                          );
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text(
                                    'Cannot view camera: Patient data missing.')),
                          );
                        }
                      },
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
