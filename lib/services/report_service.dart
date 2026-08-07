import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

class ReportService {
  static const String geminiApiKey = "my api key";
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<String> generateDailyReport(String deviceId, DateTime date) async {
    try {
      // Calculate start and end of the day
      DateTime startOfDay = DateTime(date.year, date.month, date.day);
      DateTime endOfDay = startOfDay.add(const Duration(days: 1));

      // Query events from patient_events (which we started using in Phase 3)
      QuerySnapshot eventSnapshot = await _firestore
          .collection('patient_events')
          .where('deviceId', isEqualTo: deviceId)
          .where('timestamp',
              isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
          .where('timestamp', isLessThan: Timestamp.fromDate(endOfDay))
          .orderBy('timestamp')
          .get();

      List<QueryDocumentSnapshot> eventDocs = eventSnapshot.docs;

      // Also query activity_log for the day
      QuerySnapshot activitySnapshot = await _firestore
          .collection('activity_log')
          .where('deviceId', isEqualTo: deviceId)
          .where('startTime',
              isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
          .where('startTime', isLessThan: Timestamp.fromDate(endOfDay))
          .orderBy('startTime')
          .get();

      List<QueryDocumentSnapshot> activityDocs = activitySnapshot.docs;

      if (eventDocs.isEmpty && activityDocs.isEmpty) {
        return "No events or activities recorded for this patient today. The patient had a normal, quiet day.";
      }

      // Format the raw events list
      List<String> rawLines = [];

      rawLines.add("--- ABNORMAL EVENTS ---");
      if (eventDocs.isEmpty) {
        rawLines.add("No abnormal events detected.");
      } else {
        for (var doc in eventDocs) {
          final data = doc.data() as Map<String, dynamic>;
          final String eventType = data['eventType'] ?? 'unknown';
          final Timestamp timestamp = data['timestamp'] as Timestamp;
          final formattedTime = DateFormat.Hm().format(timestamp.toDate());
          rawLines.add("- $eventType at $formattedTime");
        }
      }

      rawLines.add("\n--- ACTIVITY LOG ---");
      if (activityDocs.isEmpty) {
        rawLines.add("No specific activities recorded.");
      } else {
        for (var doc in activityDocs) {
          final data = doc.data() as Map<String, dynamic>;
          final String activityType = data['activityType'] ?? 'unknown';
          final Timestamp startTime = data['startTime'] as Timestamp;
          final Timestamp? endTime = data['endTime'] as Timestamp?;

          final startStr = DateFormat.Hm().format(startTime.toDate());
          final endStr = endTime != null
              ? DateFormat.Hm().format(endTime.toDate())
              : "ongoing";

          rawLines.add("- $activityType from $startStr to $endStr");
        }
      }

      String rawDataString = rawLines.join("\n");

      // Send to Gemini
      String summary = await _callGeminiApi(rawDataString);

      // Save report to Firestore
      await _firestore.collection('daily_reports').add({
        'deviceId': deviceId,
        'date': Timestamp.fromDate(startOfDay),
        'summaryText': summary,
        'generatedAt': FieldValue.serverTimestamp(),
        'rawEventCount': eventDocs.length,
      });

      return summary;
    } catch (e) {
      debugPrint("Error generating daily report: $e");
      return "Report generation failed. Raw event log:\n(See events list for details)";
    }
  }

  Future<String> _callGeminiApi(String rawDataString) async {
    if (geminiApiKey == "YOUR_GEMINI_API_KEY_HERE" || geminiApiKey.isEmpty) {
      return "Gemini API key not configured. Raw events:\n$rawDataString";
    }

    final url = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$geminiApiKey');

    final prompt = """
Summarize this patient's day based on the following event logs:
$rawDataString

What time normal activity happened (if implied by lack of events), what time abnormal events occurred, and overall pattern. 
Keep it under 150 words, professional doctor-friendly tone, in simple English.
""";

    try {
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          "contents": [
            {
              "parts": [
                {"text": prompt}
              ]
            }
          ]
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final candidates = data['candidates'] as List;
        if (candidates.isNotEmpty) {
          final content = candidates[0]['content'];
          final parts = content['parts'] as List;
          if (parts.isNotEmpty) {
            return parts[0]['text'] ?? 'Failed to parse summary text.';
          }
        }
        return "Received empty response from Gemini.";
      } else {
        debugPrint(
            "Gemini API Error: ${response.statusCode} - ${response.body}");
        return "Failed to generate report from Gemini API. Error: ${response.statusCode}";
      }
    } catch (e) {
      debugPrint("Exception calling Gemini: $e");
      throw Exception("API Call Failed");
    }
  }
}
