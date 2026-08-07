import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

class WhatsAppService {
  static const String accessToken = 'YOUR_ACCESS_TOKEN';
  static const String phoneNumberId = 'YOUR_PHONE_NUMBER_ID';
  static const String recipientNumber = 'YOUR_RECIPIENT_NUMBER'; // e.g., '1234567890' with country code

  Future<void> sendAlert(String eventType, DateTime timestamp) async {
    final url = Uri.parse('https://graph.facebook.com/v17.0/$phoneNumberId/messages');
    
    final formattedTime = '${timestamp.hour}:${timestamp.minute.toString().padLeft(2, '0')}';
    
    String messageContent = '';
    if (eventType == 'fall') {
      messageContent = '⚠️ Fall Alert: Patient fall detected at $formattedTime.';
    } else if (eventType == 'prolonged_stillness') {
      messageContent = '⚠️ No movement detected for 15+ minutes at $formattedTime. Please check on patient.';
    } else if (eventType == 'restless_movement') {
      messageContent = '⚠️ Unusual restless movement detected at $formattedTime. Please check on patient.';
    } else {
      messageContent = '⚠️ Alert: $eventType detected at $formattedTime.';
    }

    try {
      final response = await http.post(
        url,
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'messaging_product': 'whatsapp',
          'to': recipientNumber,
          'type': 'text',
          'text': {
            'body': messageContent,
          }
        }),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        debugPrint('WhatsApp alert sent successfully');
      } else {
        debugPrint('Failed to send WhatsApp alert: ${response.body}');
      }
    } catch (e) {
      debugPrint('Error sending WhatsApp alert: $e');
    }
  }
}
