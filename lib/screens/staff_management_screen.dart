import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/data_retention_service.dart';

class StaffManagementScreen extends StatefulWidget {
  const StaffManagementScreen({Key? key}) : super(key: key);

  @override
  State<StaffManagementScreen> createState() => _StaffManagementScreenState();
}

class _StaffManagementScreenState extends State<StaffManagementScreen> {
  final DataRetentionService _retentionService = DataRetentionService();
  bool _isCleaningUp = false;

  void _runDataCleanup() async {
    setState(() => _isCleaningUp = true);
    await _retentionService.cleanupOldEvents();
    setState(() => _isCleaningUp = false);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Data cleanup complete')),
      );
    }
  }

  void _showAddStaffDialog() {
    // Note: Creating the actual Firebase Auth account for new staff should
    // be a manual step in Firebase Console for this MVP. This dialog just manages
    // the Firestore staff profile data.

    final nameController = TextEditingController();
    final uidController = TextEditingController();
    String selectedRole = 'nurse';
    final roomsController = TextEditingController();

    showDialog(
        context: context,
        builder: (context) {
          return StatefulBuilder(builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Add Staff Profile'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                        'Ensure Auth account exists in Firebase Console first.',
                        style: TextStyle(color: Colors.grey, fontSize: 12)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: uidController,
                      decoration:
                          const InputDecoration(labelText: 'Firebase Auth UID'),
                    ),
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(labelText: 'Name'),
                    ),
                    DropdownButtonFormField<String>(
                      initialValue: selectedRole,
                      decoration: const InputDecoration(labelText: 'Role'),
                      items: const [
                        DropdownMenuItem(
                            value: 'doctor', child: Text('Doctor')),
                        DropdownMenuItem(value: 'nurse', child: Text('Nurse')),
                        DropdownMenuItem(value: 'admin', child: Text('Admin')),
                      ],
                      onChanged: (val) {
                        setDialogState(() {
                          selectedRole = val!;
                        });
                      },
                    ),
                    TextField(
                      controller: roomsController,
                      decoration: const InputDecoration(
                          labelText: 'Assigned Rooms (comma separated)'),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    if (uidController.text.isNotEmpty &&
                        nameController.text.isNotEmpty) {
                      List<String> rooms = roomsController.text
                          .split(',')
                          .map((s) => s.trim())
                          .where((s) => s.isNotEmpty)
                          .toList();
                      await FirebaseFirestore.instance
                          .collection('staff')
                          .doc(uidController.text.trim())
                          .set({
                        'name': nameController.text.trim(),
                        'role': selectedRole,
                        'assignedRooms': rooms,
                      });
                      if (context.mounted) Navigator.pop(context);
                    }
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          });
        });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Staff Management'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: 'Run Data Cleanup',
            onPressed: _isCleaningUp ? null : _runDataCleanup,
          ),
          IconButton(
            icon: const Icon(Icons.person_add),
            tooltip: 'Add Staff Profile',
            onPressed: _showAddStaffDialog,
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance.collection('staff').snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return const Center(child: Text('No staff profiles found.'));
          }

          return ListView.builder(
            itemCount: snapshot.data!.docs.length,
            itemBuilder: (context, index) {
              final doc = snapshot.data!.docs[index];
              final data = doc.data() as Map<String, dynamic>;
              final String name = data['name'] ?? 'Unknown';
              final String role = data['role'] ?? 'nurse';
              final List rooms = data['assignedRooms'] ?? [];

              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: role == 'admin'
                      ? Colors.red
                      : (role == 'doctor' ? Colors.blue : Colors.green),
                  child: Icon(
                      role == 'admin'
                          ? Icons.admin_panel_settings
                          : Icons.person,
                      color: Colors.white),
                ),
                title: Text(name),
                subtitle: Text(
                    'Role: ${role.toUpperCase()} | Rooms: ${rooms.isEmpty ? "All" : rooms.join(", ")}'),
                trailing: Text('${doc.id.substring(0, 5)}...'), // preview UID
              );
            },
          );
        },
      ),
    );
  }
}
