import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/patient.dart';
import '../services/report_service.dart';
import '../camera_screen.dart';
import '../main.dart'; // to get cameras

class DashboardScreen extends StatefulWidget {
  final Patient patient;
  const DashboardScreen({Key? key, required this.patient}) : super(key: key);

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final ReportService _reportService = ReportService();
  late String _deviceId;

  String? _generatedReport;
  bool _isGeneratingReport = false;
  late DateTime _startOfDay;

  @override
  void initState() {
    super.initState();
    _deviceId = widget.patient.deviceId;
    final now = DateTime.now();
    _startOfDay = DateTime(now.year, now.month, now.day);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.patient.name} Dashboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.camera_alt),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => CameraScreen(cameras: cameras, patient: widget.patient)),
              );
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 3a. Live status card
              _buildLiveStatusCard(),
              const SizedBox(height: 16),

              // 5. Event Timeline Visualization
              const Text('Today\'s Activity Timeline', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              _buildTimeline(_startOfDay),
              const SizedBox(height: 24),

              // 3b. Scrollable list of today's logged events
              const Text('Recent Events Today', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              _buildTodayEventsList(_startOfDay),
              const SizedBox(height: 24),

              // 2 & 3c. Generate Report Button
              ElevatedButton.icon(
                icon: const Icon(Icons.summarize),
                label: const Text("Generate Today's Report"),
                onPressed: _isGeneratingReport
                    ? null
                    : () async {
                        setState(() {
                          _isGeneratingReport = true;
                          _generatedReport = null;
                        });
                        String result = await _reportService.generateDailyReport(_deviceId, DateTime.now());
                        setState(() {
                          _generatedReport = result;
                          _isGeneratingReport = false;
                        });
                      },
              ),
              const SizedBox(height: 16),
              
              // 6. Video Privacy Toggle
              SwitchListTile(
                title: const Text('Video Privacy (Face Blur)'),
                subtitle: const Text('Apply mask over patient\'s face on camera feed'),
                value: widget.patient.blurFaceEnabled,
                onChanged: (bool value) async {
                  await FirebaseFirestore.instance.collection('patients').doc(widget.patient.patientId).update({
                    'blurFaceEnabled': value,
                  });
                  // Local state is updated via the patient object passed, but for immediate reflection:
                  // For a real app we might want to listen to the document stream for this.
                  // For MVP, just show a snackbar or note.
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Privacy mask ${value ? 'enabled' : 'disabled'}. Changes will apply to next feed.')),
                    );
                  }
                },
              ),
              const SizedBox(height: 16),

              // 3d. Generated Report Card
              if (_isGeneratingReport)
                const Center(child: CircularProgressIndicator())
              else if (_generatedReport != null)
                Card(
                  color: Colors.blue.shade50,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Daily Summary Report', style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        Text(_generatedReport!),
                      ],
                    ),
                  ),
                ),

              const SizedBox(height: 24),

              // 3e. Past daily reports
              const Text('Past Daily Reports', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              _buildPastReportsList(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLiveStatusCard() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('patient_events')
          .where('deviceId', isEqualTo: _deviceId)
          .orderBy('timestamp', descending: true)
          .limit(1)
          .snapshots(),
      builder: (context, snapshot) {
        String statusText = 'Monitoring...';
        Color statusColor = Colors.green.shade600;

        if (snapshot.hasData && snapshot.data!.docs.isNotEmpty) {
          final data = snapshot.data!.docs.first.data() as Map<String, dynamic>;
          final timestamp = data['timestamp'] as Timestamp?;
          final eventType = data['eventType'] as String? ?? 'event';

          if (timestamp != null) {
            final timeDiff = DateTime.now().difference(timestamp.toDate());
            // If an event happened in the last 15 minutes, show it as current status
            if (timeDiff.inMinutes < 15) {
              if (eventType == 'fall') {
                statusText = '⚠️ FALL DETECTED';
                statusColor = Colors.red.shade700;
              } else if (eventType == 'restless_movement') {
                statusText = '⚠️ RESTLESS MOVEMENT';
                statusColor = Colors.purple.shade700;
              } else if (eventType == 'prolonged_stillness') {
                statusText = '⚠️ PROLONGED STILLNESS';
                statusColor = Colors.blue.shade700;
              } else {
                statusText = '⚠️ EVENT DETECTED';
                statusColor = Colors.orange.shade700;
              }
            }
          }
        }

        return Container(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          decoration: BoxDecoration(
            color: statusColor.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.monitor_heart, color: Colors.white),
              const SizedBox(width: 8),
              Text(
                statusText,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTimeline(DateTime startOfDay) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('patient_events')
          .where('deviceId', isEqualTo: _deviceId)
          .where('timestamp', isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
          .snapshots(),
      builder: (context, snapshot) {
        // 24 hours, default color light grey
        List<Color> hourColors = List.filled(24, Colors.grey.shade300);

        if (snapshot.hasData) {
          for (var doc in snapshot.data!.docs) {
            final data = doc.data() as Map<String, dynamic>;
            final timestamp = data['timestamp'] as Timestamp?;
            final eventType = data['eventType'] as String?;
            if (timestamp != null) {
              int hour = timestamp.toDate().hour;
              if (eventType == 'fall') {
                hourColors[hour] = Colors.red;
              } else if (eventType == 'restless_movement' && hourColors[hour] != Colors.red) {
                hourColors[hour] = Colors.purple;
              } else if (eventType == 'prolonged_stillness' && hourColors[hour] != Colors.red && hourColors[hour] != Colors.purple) {
                hourColors[hour] = Colors.blue;
              }
            }
          }
        }

        return Row(
          children: List.generate(24, (index) {
            return Expanded(
              child: Container(
                height: 20,
                margin: const EdgeInsets.symmetric(horizontal: 1),
                decoration: BoxDecoration(
                  color: hourColors[index],
                  borderRadius: BorderRadius.circular(2),
                ),
                child: Tooltip(
                  message: '${index.toString().padLeft(2, '0')}:00',
                  child: Container(),
                ),
              ),
            );
          }),
        );
      },
    );
  }

  Widget _buildTodayEventsList(DateTime startOfDay) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('patient_events')
          .where('deviceId', isEqualTo: _deviceId)
          .where('timestamp', isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
          .orderBy('timestamp', descending: true)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return const Text('No abnormal events detected today.');
        }

        return ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: snapshot.data!.docs.length,
          itemBuilder: (context, index) {
            final data = snapshot.data!.docs[index].data() as Map<String, dynamic>;
            final eventType = data['eventType'] as String? ?? 'unknown';
            final timestamp = data['timestamp'] as Timestamp?;

            IconData icon = Icons.info;
            Color color = Colors.grey;
            String eventName = 'Unknown Event';

            if (eventType == 'fall') {
              icon = Icons.warning;
              color = Colors.red;
              eventName = 'Fall Detected';
            } else if (eventType == 'prolonged_stillness') {
              icon = Icons.bedtime;
              color = Colors.blue;
              eventName = 'Prolonged Stillness';
            } else if (eventType == 'restless_movement') {
              icon = Icons.directions_run;
              color = Colors.purple;
              eventName = 'Restless Movement';
            }

            String timeStr = '';
            if (timestamp != null) {
              timeStr = DateFormat.Hm().format(timestamp.toDate());
            }

            return ListTile(
              leading: Icon(icon, color: color),
              title: Text(eventName),
              subtitle: Text(timeStr),
              dense: true,
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                tooltip: 'Delete Event',
                onPressed: () async {
                  await snapshot.data!.docs[index].reference.delete();
                },
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPastReportsList() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('daily_reports')
          .where('deviceId', isEqualTo: _deviceId)
          .orderBy('date', descending: true)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return const Text('No past reports available.');
        }

        return ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: snapshot.data!.docs.length,
          itemBuilder: (context, index) {
            final data = snapshot.data!.docs[index].data() as Map<String, dynamic>;
            final date = data['date'] as Timestamp?;
            final summary = data['summaryText'] as String? ?? '';

            String dateStr = '';
            if (date != null) {
              dateStr = DateFormat.yMMMd().format(date.toDate());
            }

            return ExpansionTile(
              title: Text('Report: $dateStr'),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                tooltip: 'Delete Report',
                onPressed: () async {
                  await snapshot.data!.docs[index].reference.delete();
                },
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Text(summary),
                )
              ],
            );
          },
        );
      },
    );
  }
}
