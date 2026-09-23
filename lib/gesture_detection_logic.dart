import 'dart:math';
import 'package:flutter/material.dart';
import 'models/pose.dart';

enum DetectedGesture {
  none,
  emergencyHelpWave,
  washroomRequest,
  waterRequest,
  blanketRequest,
  chestPainDistress,
}

class GestureResult {
  final DetectedGesture gesture;
  final String eventType;
  final String displayTitle;
  final String alertMessage;
  final bool isConfirmed;
  final bool isHolding;
  final double holdProgress;
  final String holdFeedbackText;
  final Color holdColor;

  const GestureResult({
    required this.gesture,
    required this.eventType,
    required this.displayTitle,
    required this.alertMessage,
    this.isConfirmed = false,
    this.isHolding = false,
    this.holdProgress = 0.0,
    this.holdFeedbackText = '',
    this.holdColor = Colors.orange,
  });

  static const empty = GestureResult(
    gesture: DetectedGesture.none,
    eventType: '',
    displayTitle: '',
    alertMessage: '',
    isConfirmed: false,
    isHolding: false,
    holdProgress: 0.0,
    holdFeedbackText: '',
    holdColor: Colors.grey,
  );
}

class GestureDetectionLogic {
  // 3.0 seconds intentional hold required to prevent accidental triggers
  static const int holdDurationMs = 3000;

  // Cooldowns per gesture to prevent spamming notifications
  final Map<DetectedGesture, DateTime> _lastTriggered = {};
  static const Duration _cooldown = Duration(seconds: 30);

  // Time accumulators for gestures requiring sustained hold
  DateTime? _waterGestureStart;
  DateTime? _washroomGestureStart;
  DateTime? _blanketGestureStart;
  DateTime? _chestPainGestureStart;

  // Wave detection tracking: list of timestamped wrist X positions
  final List<double> _wristXHistory = [];
  final List<DateTime> _wristTimeHistory = [];

  GestureResult detectGesture(Pose pose) {
    if (pose.landmarks.isEmpty) {
      _resetHoldTimers();
      return GestureResult.empty;
    }

    final now = DateTime.now();

    final nose = pose.landmarks[PoseLandmarkType.nose];
    final leftShoulder = pose.landmarks[PoseLandmarkType.leftShoulder];
    final rightShoulder = pose.landmarks[PoseLandmarkType.rightShoulder];
    final leftElbow = pose.landmarks[PoseLandmarkType.leftElbow];
    final rightElbow = pose.landmarks[PoseLandmarkType.rightElbow];
    final leftWrist = pose.landmarks[PoseLandmarkType.leftWrist];
    final rightWrist = pose.landmarks[PoseLandmarkType.rightWrist];
    final leftHip = pose.landmarks[PoseLandmarkType.leftHip];
    final rightHip = pose.landmarks[PoseLandmarkType.rightHip];

    if (leftShoulder == null || rightShoulder == null) {
      _resetHoldTimers();
      return GestureResult.empty;
    }

    // Body scale reference metrics
    final shoulderWidth = (leftShoulder.x - rightShoulder.x).abs();
    if (shoulderWidth < 20) {
      _resetHoldTimers();
      return GestureResult.empty; // Person too small or invalid pose
    }

    final midShoulderX = (leftShoulder.x + rightShoulder.x) / 2.0;
    final midShoulderY = (leftShoulder.y + rightShoulder.y) / 2.0;

    double midHipX = midShoulderX;
    double midHipY = midShoulderY + shoulderWidth * 1.5;
    if (leftHip != null && rightHip != null) {
      midHipX = (leftHip.x + rightHip.x) / 2.0;
      midHipY = (leftHip.y + rightHip.y) / 2.0;
    }

    final chestX = midShoulderX;
    final chestY = midShoulderY + (midHipY - midShoulderY) * 0.35;

    // -------------------------------------------------------------
    // 1. EMERGENCY HELP WAVE (हाथ हिलाकर मदद मांगना) - Priority: RED
    // -------------------------------------------------------------
    if (!_isCoolingDown(DetectedGesture.emergencyHelpWave, now)) {
      final leftHandAboveHead = leftWrist != null && leftWrist.y < leftShoulder.y - (shoulderWidth * 0.2);
      final rightHandAboveHead = rightWrist != null && rightWrist.y < rightShoulder.y - (shoulderWidth * 0.2);

      if (leftHandAboveHead || rightHandAboveHead) {
        final activeWrist = rightHandAboveHead ? rightWrist : leftWrist!;

        _wristXHistory.add(activeWrist.x);
        _wristTimeHistory.add(now);

        // Keep last 2 seconds of history
        while (_wristTimeHistory.isNotEmpty && now.difference(_wristTimeHistory.first).inMilliseconds > 2000) {
          _wristXHistory.removeAt(0);
          _wristTimeHistory.removeAt(0);
        }

        if (_isOscillatingWave(_wristXHistory, shoulderWidth * 0.25)) {
          _wristXHistory.clear();
          _wristTimeHistory.clear();
          _lastTriggered[DetectedGesture.emergencyHelpWave] = now;
          return const GestureResult(
            gesture: DetectedGesture.emergencyHelpWave,
            eventType: 'emergency_help_wave',
            displayTitle: '🚨 HELP WAVE DETECTED',
            alertMessage: 'Patient is waving for emergency help! Immediate assistance required.',
            isConfirmed: true,
            holdProgress: 1.0,
          );
        }
      } else {
        _wristXHistory.clear();
        _wristTimeHistory.clear();
      }
    }

    // -------------------------------------------------------------
    // 2. CHEST PAIN / LEVINE'S SIGN (छाती पर हाथ - Severe Pain) - Priority: ORANGE
    // -------------------------------------------------------------
    if (!_isCoolingDown(DetectedGesture.chestPainDistress, now)) {
      bool handOnChest = false;
      if (leftWrist != null) {
        final dist = _distance(leftWrist.x, leftWrist.y, chestX, chestY);
        if (dist < shoulderWidth * 0.35) handOnChest = true;
      }
      if (rightWrist != null) {
        final dist = _distance(rightWrist.x, rightWrist.y, chestX, chestY);
        if (dist < shoulderWidth * 0.35) handOnChest = true;
      }

      if (handOnChest) {
        _chestPainGestureStart ??= now;
        final elapsed = now.difference(_chestPainGestureStart!).inMilliseconds;
        final progress = (elapsed / holdDurationMs).clamp(0.0, 1.0);

        if (elapsed >= holdDurationMs) {
          _chestPainGestureStart = null;
          _lastTriggered[DetectedGesture.chestPainDistress] = now;
          return const GestureResult(
            gesture: DetectedGesture.chestPainDistress,
            eventType: 'chest_pain_distress',
            displayTitle: '⚠️ CHEST PAIN DISTRESS DETECTED',
            alertMessage: 'Patient clutching chest (possible acute pain or cardiac distress).',
            isConfirmed: true,
            holdProgress: 1.0,
          );
        } else {
          final elapsedSec = (elapsed / 1000.0).toStringAsFixed(1);
          return GestureResult(
            gesture: DetectedGesture.chestPainDistress,
            eventType: 'chest_pain_distress',
            displayTitle: 'HOLDING: Chest Pain Sign',
            alertMessage: '',
            isConfirmed: false,
            isHolding: true,
            holdProgress: progress,
            holdFeedbackText: 'HOLD ($elapsedSec s / 3.0s): CHEST PAIN SIGN',
            holdColor: Colors.deepOrange,
          );
        }
      } else {
        _chestPainGestureStart = null;
      }
    }

    // -------------------------------------------------------------
    // 3. WATER REQUEST (पानी का इशारा - Hand Near Mouth) - Priority: BLUE
    // -------------------------------------------------------------
    if (!_isCoolingDown(DetectedGesture.waterRequest, now) && nose != null) {
      bool handNearMouth = false;
      if (leftWrist != null) {
        final dist = _distance(leftWrist.x, leftWrist.y, nose.x, nose.y + (shoulderWidth * 0.15));
        if (dist < shoulderWidth * 0.38) handNearMouth = true;
      }
      if (rightWrist != null) {
        final dist = _distance(rightWrist.x, rightWrist.y, nose.x, nose.y + (shoulderWidth * 0.15));
        if (dist < shoulderWidth * 0.38) handNearMouth = true;
      }

      if (handNearMouth) {
        _waterGestureStart ??= now;
        final elapsed = now.difference(_waterGestureStart!).inMilliseconds;
        final progress = (elapsed / holdDurationMs).clamp(0.0, 1.0);

        if (elapsed >= holdDurationMs) {
          _waterGestureStart = null;
          _lastTriggered[DetectedGesture.waterRequest] = now;
          return const GestureResult(
            gesture: DetectedGesture.waterRequest,
            eventType: 'water_request',
            displayTitle: '💧 WATER REQUESTED',
            alertMessage: 'Patient is thirsty and requesting water / hydration assistance.',
            isConfirmed: true,
            holdProgress: 1.0,
          );
        } else {
          final elapsedSec = (elapsed / 1000.0).toStringAsFixed(1);
          return GestureResult(
            gesture: DetectedGesture.waterRequest,
            eventType: 'water_request',
            displayTitle: 'HOLDING: Water Request',
            alertMessage: '',
            isConfirmed: false,
            isHolding: true,
            holdProgress: progress,
            holdFeedbackText: 'HOLD ($elapsedSec s / 3.0s): 💧 WATER REQUEST',
            holdColor: Colors.blue,
          );
        }
      } else {
        _waterGestureStart = null;
      }
    }

    // -------------------------------------------------------------
    // 4. WASHROOM / TOILET REQUEST (टॉयलेट जाना है - Steady Raised Hand or Pelvic Sign) - Priority: AMBER
    // -------------------------------------------------------------
    if (!_isCoolingDown(DetectedGesture.washroomRequest, now)) {
      // Steady raised hand (forearm upright without waving) OR hand resting over lower abdomen
      bool steadyRaisedHand = false;
      if (rightWrist != null && rightElbow != null) {
        final isUpright = rightWrist.y < rightElbow.y && (rightWrist.x - rightElbow.x).abs() < shoulderWidth * 0.4;
        if (isUpright && rightWrist.y < rightShoulder.y) steadyRaisedHand = true;
      }
      if (leftWrist != null && leftElbow != null) {
        final isUpright = leftWrist.y < leftElbow.y && (leftWrist.x - leftElbow.x).abs() < shoulderWidth * 0.4;
        if (isUpright && leftWrist.y < leftShoulder.y) steadyRaisedHand = true;
      }

      // Hand on lower abdomen (pelvic area)
      bool handOnAbdomen = false;
      if (leftWrist != null) {
        final dist = _distance(leftWrist.x, leftWrist.y, midHipX, midHipY);
        if (dist < shoulderWidth * 0.4) handOnAbdomen = true;
      }
      if (rightWrist != null) {
        final dist = _distance(rightWrist.x, rightWrist.y, midHipX, midHipY);
        if (dist < shoulderWidth * 0.4) handOnAbdomen = true;
      }

      if (steadyRaisedHand || handOnAbdomen) {
        _washroomGestureStart ??= now;
        final elapsed = now.difference(_washroomGestureStart!).inMilliseconds;
        final progress = (elapsed / holdDurationMs).clamp(0.0, 1.0);

        if (elapsed >= holdDurationMs) {
          _washroomGestureStart = null;
          _lastTriggered[DetectedGesture.washroomRequest] = now;
          return const GestureResult(
            gesture: DetectedGesture.washroomRequest,
            eventType: 'washroom_request',
            displayTitle: '🚻 WASHROOM ASSISTANCE REQUESTED',
            alertMessage: 'Patient needs toilet / washroom assistance. Routine care needed.',
            isConfirmed: true,
            holdProgress: 1.0,
          );
        } else {
          final elapsedSec = (elapsed / 1000.0).toStringAsFixed(1);
          return GestureResult(
            gesture: DetectedGesture.washroomRequest,
            eventType: 'washroom_request',
            displayTitle: 'HOLDING: Washroom Request',
            alertMessage: '',
            isConfirmed: false,
            isHolding: true,
            holdProgress: progress,
            holdFeedbackText: 'HOLD ($elapsedSec s / 3.0s): 🚻 WASHROOM REQUEST',
            holdColor: Colors.amber.shade800,
          );
        }
      } else {
        _washroomGestureStart = null;
      }
    }

    // -------------------------------------------------------------
    // 5. BLANKET / COLD (ठंड / चादर - Crossed Arms Hugging Self) - Priority: TEAL
    // -------------------------------------------------------------
    if (!_isCoolingDown(DetectedGesture.blanketRequest, now)) {
      bool armsCrossed = false;
      if (leftWrist != null && rightWrist != null) {
        final leftCrossed = leftWrist.x > midShoulderX;
        final rightCrossed = rightWrist.x < midShoulderX;
        final wristsNearChest = (leftWrist.y - chestY).abs() < shoulderWidth * 0.6 &&
                                (rightWrist.y - chestY).abs() < shoulderWidth * 0.6;
        if (leftCrossed && rightCrossed && wristsNearChest) {
          armsCrossed = true;
        }
      }

      if (armsCrossed) {
        _blanketGestureStart ??= now;
        final elapsed = now.difference(_blanketGestureStart!).inMilliseconds;
        final progress = (elapsed / holdDurationMs).clamp(0.0, 1.0);

        if (elapsed >= holdDurationMs) {
          _blanketGestureStart = null;
          _lastTriggered[DetectedGesture.blanketRequest] = now;
          return const GestureResult(
            gesture: DetectedGesture.blanketRequest,
            eventType: 'blanket_request',
            displayTitle: '🛌 BLANKET / COLD REPORTED',
            alertMessage: 'Patient is feeling cold and requesting an extra blanket.',
            isConfirmed: true,
            holdProgress: 1.0,
          );
        } else {
          final elapsedSec = (elapsed / 1000.0).toStringAsFixed(1);
          return GestureResult(
            gesture: DetectedGesture.blanketRequest,
            eventType: 'blanket_request',
            displayTitle: 'HOLDING: Blanket Request',
            alertMessage: '',
            isConfirmed: false,
            isHolding: true,
            holdProgress: progress,
            holdFeedbackText: 'HOLD ($elapsedSec s / 3.0s): 🛌 BLANKET REQUEST',
            holdColor: Colors.teal,
          );
        }
      } else {
        _blanketGestureStart = null;
      }
    }

    return GestureResult.empty;
  }

  void _resetHoldTimers() {
    _waterGestureStart = null;
    _washroomGestureStart = null;
    _blanketGestureStart = null;
    _chestPainGestureStart = null;
    _wristXHistory.clear();
    _wristTimeHistory.clear();
  }

  bool _isCoolingDown(DetectedGesture gesture, DateTime now) {
    final lastTime = _lastTriggered[gesture];
    if (lastTime == null) return false;
    return now.difference(lastTime) < _cooldown;
  }

  double _distance(double x1, double y1, double x2, double y2) {
    return sqrt((x1 - x2) * (x1 - x2) + (y1 - y2) * (y1 - y2));
  }

  bool _isOscillatingWave(List<double> xVals, double minAmplitude) {
    if (xVals.length < 8) return false;

    // Detect direction reversals (peaks and valleys)
    int reversals = 0;
    double? lastDir;

    for (int i = 1; i < xVals.length; i++) {
      final diff = xVals[i] - xVals[i - 1];
      if (diff.abs() > 3.0) {
        final currentDir = diff > 0 ? 1.0 : -1.0;
        if (lastDir != null && currentDir != lastDir) {
          reversals++;
        }
        lastDir = currentDir;
      }
    }

    final range = xVals.reduce(max) - xVals.reduce(min);
    return reversals >= 3 && range >= minAmplitude;
  }
}
