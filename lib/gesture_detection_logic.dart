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
  // Intentional hold durations required to prevent accidental triggers
  static const int holdDurationMs = 3000;
  static const int waterHoldDurationMs = 5000; // 5.0 seconds hold for ASL Water Sign
  static const int chestHoldDurationMs = 7000; // 7.0 seconds hold with both hands on chest
  static const int blanketHoldDurationMs = 7000; // 7.0 seconds hold with hands crossed on shoulders

  // Cooldowns per gesture to prevent spamming notifications
  final Map<DetectedGesture, DateTime> _lastTriggered = {};
  static const Duration _cooldown = Duration(seconds: 30);

  // Time accumulators for gestures requiring sustained hold
  DateTime? _waterGestureStart;
  DateTime? _washroomGestureStart;
  DateTime? _blanketGestureStart;

  // Chest Pain Distress tracking: 7s Hold with Both Hands + 3 Fist Close-Open Cycles
  DateTime? _chestPainHoldStart;
  String _chestPainPhase = "IDLE"; // "IDLE", "HOLD_7S", "WAIT_CLOSE", "WAIT_OPEN"
  int _chestPainCycles = 0;
  DateTime? _chestPainPhaseTime;
  DateTime? _chestPainPumpsStartTime;
  DateTime? _chestPainLastHandsNear;

  // Emergency Help tracking: 3 Open-Close cycles
  int _emergencyCycles = 0;
  String _emergencyPhase = "IDLE"; // "IDLE", "WAIT_CLOSE", "WAIT_OPEN"
  DateTime? _emergencyPhaseTime;
  DateTime? _emergencyStartTime;

  GestureResult detectGesture(Pose pose) {
    if (pose.landmarks.isEmpty) {
      _resetHoldTimers();
      return GestureResult.empty;
    }

    final now = DateTime.now();

    final leftShoulder = pose.landmarks[PoseLandmarkType.leftShoulder];
    final rightShoulder = pose.landmarks[PoseLandmarkType.rightShoulder];
    final leftElbow = pose.landmarks[PoseLandmarkType.leftElbow];
    final rightElbow = pose.landmarks[PoseLandmarkType.rightElbow];
    final leftWrist = pose.landmarks[PoseLandmarkType.leftWrist];
    final rightWrist = pose.landmarks[PoseLandmarkType.rightWrist];
    final leftHip = pose.landmarks[PoseLandmarkType.leftHip];
    final rightHip = pose.landmarks[PoseLandmarkType.rightHip];
    final leftIndex = pose.landmarks[PoseLandmarkType.leftIndex];
    final rightIndex = pose.landmarks[PoseLandmarkType.rightIndex];
    final leftPinky = pose.landmarks[PoseLandmarkType.leftPinky];
    final rightPinky = pose.landmarks[PoseLandmarkType.rightPinky];
    final leftThumb = pose.landmarks[PoseLandmarkType.leftThumb];
    final rightThumb = pose.landmarks[PoseLandmarkType.rightThumb];

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

    // Hand shape classification (ASL Water Sign: 3 fingers up, thumb & pinky joined)
    final leftWaterSign = _isWaterSign(leftWrist, leftIndex, leftPinky, leftThumb, shoulderWidth);
    final rightWaterSign = _isWaterSign(rightWrist, rightIndex, rightPinky, rightThumb, shoulderWidth);
    final leftOpenPalm = _isOpenPalm(leftWrist, leftIndex, leftPinky, leftThumb, shoulderWidth);
    final rightOpenPalm = _isOpenPalm(rightWrist, rightIndex, rightPinky, rightThumb, shoulderWidth);
    final leftFist = _isFist(leftWrist, leftIndex, leftPinky, shoulderWidth) && !leftWaterSign;
    final rightFist = _isFist(rightWrist, rightIndex, rightPinky, shoulderWidth) && !rightWaterSign;
    final leftOneFinger = _isOneFinger(leftWrist, leftIndex, leftPinky, leftThumb, shoulderWidth);
    final rightOneFinger = _isOneFinger(rightWrist, rightIndex, rightPinky, rightThumb, shoulderWidth);

    // -------------------------------------------------------------
    // 1. EMERGENCY HELP: 3 OPEN & CLOSE FIST CYCLES (🖐 -> ✊ -> 🖐 x3)
    // -------------------------------------------------------------
    if (!_isCoolingDown(DetectedGesture.emergencyHelpWave, now)) {
      final leftHandAboveHead = leftWrist != null && leftWrist.y < leftShoulder.y - (shoulderWidth * 0.15);
      final rightHandAboveHead = rightWrist != null && rightWrist.y < rightShoulder.y - (shoulderWidth * 0.15);

      if (leftHandAboveHead || rightHandAboveHead) {
        final isOpen = rightHandAboveHead ? rightOpenPalm : leftOpenPalm;
        final isFist = rightHandAboveHead ? rightFist : leftFist;

        // Reset if total interaction takes more than 10 seconds
        if (_emergencyStartTime != null && now.difference(_emergencyStartTime!).inMilliseconds > 10000) {
          _emergencyCycles = 0;
          _emergencyPhase = "IDLE";
          _emergencyStartTime = null;
        }

        final canShift = (_emergencyPhaseTime == null) || (now.difference(_emergencyPhaseTime!).inMilliseconds >= 120);

        if (_emergencyPhase == "IDLE") {
          if (isOpen) {
            _emergencyPhase = "WAIT_CLOSE";
            _emergencyPhaseTime = now;
            _emergencyStartTime = now;
            _emergencyCycles = 0;
          }
        } else if (_emergencyPhase == "WAIT_CLOSE") {
          if (isFist && canShift) {
            _emergencyPhase = "WAIT_OPEN";
            _emergencyPhaseTime = now;
          }
        } else if (_emergencyPhase == "WAIT_OPEN") {
          if (isOpen && canShift) {
            _emergencyCycles++;
            _emergencyPhaseTime = now;

            if (_emergencyCycles >= 3) {
              _emergencyCycles = 0;
              _emergencyPhase = "IDLE";
              _emergencyStartTime = null;
              _emergencyPhaseTime = null;
              _lastTriggered[DetectedGesture.emergencyHelpWave] = now;
              return const GestureResult(
                gesture: DetectedGesture.emergencyHelpWave,
                eventType: 'emergency_help_wave',
                displayTitle: '🚨 EMERGENCY HELP DETECTED',
                alertMessage: 'Patient opened and closed hand 3 times! Immediate emergency assistance requested.',
                isConfirmed: true,
                holdProgress: 1.0,
              );
            } else {
              _emergencyPhase = "WAIT_CLOSE";
            }
          }
        }

        if (_emergencyPhase != "IDLE") {
          final cycleProgress = (_emergencyCycles * 2 + (_emergencyPhase == "WAIT_OPEN" ? 1 : 0)) / 6.0;
          final titleMsg = _emergencyPhase == "WAIT_CLOSE"
              ? (_emergencyCycles == 0 ? "🖐 EMERGENCY: CLOSE FIST (0/3)" : "🚨 EMERGENCY: CLOSE FIST ($_emergencyCycles/3)")
              : "✊ NOW OPEN HAND (${_emergencyCycles + 1}/3)";

          return GestureResult(
            gesture: DetectedGesture.emergencyHelpWave,
            eventType: 'emergency_help_wave',
            displayTitle: titleMsg,
            alertMessage: '',
            isConfirmed: false,
            isHolding: true,
            holdProgress: cycleProgress.clamp(0.12, 1.0),
            holdFeedbackText: titleMsg,
            holdColor: Colors.red,
          );
        } else {
          return const GestureResult(
            gesture: DetectedGesture.emergencyHelpWave,
            eventType: 'emergency_help_wave',
            displayTitle: '🖐 HAND UP: Open & Close Fist 3x for Help',
            alertMessage: '',
            isConfirmed: false,
            isHolding: true,
            holdProgress: 0.08,
            holdFeedbackText: '🖐 HAND UP: Open & Close Fist 3 times for Emergency Help',
            holdColor: Colors.orange,
          );
        }
      } else {
        _emergencyCycles = 0;
        _emergencyPhase = "IDLE";
        _emergencyStartTime = null;
        _emergencyPhaseTime = null;
      }
    }

    // -------------------------------------------------------------
    // 2. CHEST PAIN DISTRESS (Both Hands on Chest 7s + 3 Close-Open Fist Cycles)
    // -------------------------------------------------------------
    if (!_isCoolingDown(DetectedGesture.chestPainDistress, now)) {
      // Both hands on chest (within 0.50 of shoulder width from chest center)
      final leftOnChest = leftWrist != null && _distance(leftWrist.x, leftWrist.y, chestX, chestY) < shoulderWidth * 0.50;
      final rightOnChest = rightWrist != null && _distance(rightWrist.x, rightWrist.y, chestX, chestY) < shoulderWidth * 0.50;
      final bothHandsOnChest = leftOnChest && rightOnChest;

      // In fist-pumping phase, at least one hand clutching or near chest (< 0.65 shoulder width)
      final leftNearChest = leftWrist != null && _distance(leftWrist.x, leftWrist.y, chestX, chestY) < shoulderWidth * 0.65;
      final rightNearChest = rightWrist != null && _distance(rightWrist.x, rightWrist.y, chestX, chestY) < shoulderWidth * 0.65;
      final handsNearChest = leftNearChest || rightNearChest;

      if (handsNearChest) {
        _chestPainLastHandsNear = now;
      }

      // If hands have been away from chest for more than 2.0s, reset
      if (_chestPainLastHandsNear != null && now.difference(_chestPainLastHandsNear!).inMilliseconds > 2000) {
        _chestPainPhase = "IDLE";
        _chestPainHoldStart = null;
        _chestPainCycles = 0;
        _chestPainPumpsStartTime = null;
      }

      // Phase 1: Hold Both Hands on Chest for 7.0 seconds
      if (_chestPainPhase == "IDLE") {
        if (bothHandsOnChest) {
          _chestPainPhase = "HOLD_7S";
          _chestPainHoldStart = now;
          _chestPainCycles = 0;
          _chestPainLastHandsNear = now;
        }
      }

      if (_chestPainPhase == "HOLD_7S") {
        if (bothHandsOnChest) {
          final elapsed = now.difference(_chestPainHoldStart ?? now).inMilliseconds;
          if (elapsed < chestHoldDurationMs) {
            final elapsedSec = (elapsed / 1000.0).toStringAsFixed(1);
            final progress = (elapsed / chestHoldDurationMs).clamp(0.0, 1.0) * 0.50;
            return GestureResult(
              gesture: DetectedGesture.chestPainDistress,
              eventType: 'chest_pain_distress',
              displayTitle: '⚠️ CHEST PAIN: Hold Both Hands ($elapsedSec s / 7.0s)',
              alertMessage: '',
              isConfirmed: false,
              isHolding: true,
              holdProgress: progress,
              holdFeedbackText: 'HOLD ($elapsedSec s / 7.0s): ⚠️ HOLD BOTH HANDS ON CHEST',
              holdColor: Colors.deepOrange,
            );
          } else {
            // 7.0s completed! Transition to Phase 2: Close & Open fist 3 times
            _chestPainPhase = "WAIT_CLOSE";
            _chestPainPumpsStartTime = now;
            _chestPainPhaseTime = now;
            _chestPainCycles = 0;
            return const GestureResult(
              gesture: DetectedGesture.chestPainDistress,
              eventType: 'chest_pain_distress',
              displayTitle: '⚠️ CHEST PAIN: Close & Open Fist 3x (0/3)',
              alertMessage: '',
              isConfirmed: false,
              isHolding: true,
              holdProgress: 0.52,
              holdFeedbackText: '✊ CHEST PAIN: CLOSE & OPEN FIST 3 TIMES',
              holdColor: Colors.red,
            );
          }
        } else {
          // Released both hands before 7s
          _chestPainPhase = "IDLE";
          _chestPainHoldStart = null;
        }
      } else if (_chestPainPhase == "WAIT_CLOSE" || _chestPainPhase == "WAIT_OPEN") {
        // Overall timeout of 12 seconds for the 3 fist cycles
        if (_chestPainPumpsStartTime != null && now.difference(_chestPainPumpsStartTime!).inMilliseconds > 12000) {
          _chestPainPhase = "IDLE";
          _chestPainHoldStart = null;
          _chestPainCycles = 0;
          _chestPainPumpsStartTime = null;
        } else {
          final isFist = leftFist || rightFist;
          final isOpen = leftOpenPalm || rightOpenPalm;
          final canShift = _chestPainPhaseTime == null || now.difference(_chestPainPhaseTime!).inMilliseconds >= 120;

          if (_chestPainPhase == "WAIT_CLOSE") {
            if (isFist && canShift) {
              _chestPainPhase = "WAIT_OPEN";
              _chestPainPhaseTime = now;
            }
          } else if (_chestPainPhase == "WAIT_OPEN") {
            if (isOpen && canShift) {
              _chestPainCycles++;
              _chestPainPhaseTime = now;
              if (_chestPainCycles >= 3) {
                // CONFIRMED TRIGGER!
                _chestPainPhase = "IDLE";
                _chestPainHoldStart = null;
                _chestPainCycles = 0;
                _chestPainPumpsStartTime = null;
                _chestPainPhaseTime = null;
                _lastTriggered[DetectedGesture.chestPainDistress] = now;
                return const GestureResult(
                  gesture: DetectedGesture.chestPainDistress,
                  eventType: 'chest_pain_distress',
                  displayTitle: '⚠️ CHEST PAIN DISTRESS DETECTED',
                  alertMessage: 'Patient held both hands on chest for 7s followed by 3 fist close-open cycles (Acute cardiac/chest distress).',
                  isConfirmed: true,
                  holdProgress: 1.0,
                );
              } else {
                _chestPainPhase = "WAIT_CLOSE";
              }
            }
          }

          final cycleProgress = 0.50 + ((_chestPainCycles * 2 + (_chestPainPhase == "WAIT_OPEN" ? 1 : 0)) / 6.0) * 0.50;
          final titleMsg = _chestPainPhase == "WAIT_CLOSE"
              ? "✊ CLOSE FIST ($_chestPainCycles/3)"
              : "🖐 OPEN FIST (${_chestPainCycles + 1}/3)";

          return GestureResult(
            gesture: DetectedGesture.chestPainDistress,
            eventType: 'chest_pain_distress',
            displayTitle: '⚠️ CHEST PAIN: $titleMsg',
            alertMessage: '',
            isConfirmed: false,
            isHolding: true,
            holdProgress: cycleProgress.clamp(0.50, 0.98),
            holdFeedbackText: '⚠️ CHEST PAIN: $titleMsg',
            holdColor: Colors.red,
          );
        }
      }
    } else {
      _chestPainPhase = "IDLE";
      _chestPainHoldStart = null;
      _chestPainCycles = 0;
      _chestPainPumpsStartTime = null;
    }

    // -------------------------------------------------------------
    // 3. WATER REQUEST (ASL 'W' Sign: 3 Fingers Up, Thumb & Pinky Joined) - 5s Hold
    // -------------------------------------------------------------
    if (!_isCoolingDown(DetectedGesture.waterRequest, now)) {
      final rightWater = rightWaterSign && rightWrist != null && rightWrist.y < midHipY;
      final leftWater = leftWaterSign && leftWrist != null && leftWrist.y < midHipY;

      if (rightWater || leftWater) {
        _waterGestureStart ??= now;
        final elapsed = now.difference(_waterGestureStart!).inMilliseconds;
        final progress = (elapsed / waterHoldDurationMs).clamp(0.0, 1.0);

        if (elapsed >= waterHoldDurationMs) {
          _waterGestureStart = null;
          _lastTriggered[DetectedGesture.waterRequest] = now;
          return const GestureResult(
            gesture: DetectedGesture.waterRequest,
            eventType: 'water_request',
            displayTitle: '💧 WATER REQUESTED (ASL Sign)',
            alertMessage: 'Patient showed 3 fingers with thumb and pinky joined (ASL Water Sign) for 5 seconds.',
            isConfirmed: true,
            holdProgress: 1.0,
          );
        } else {
          final elapsedSec = (elapsed / 1000.0).toStringAsFixed(1);
          return GestureResult(
            gesture: DetectedGesture.waterRequest,
            eventType: 'water_request',
            displayTitle: '💧 WATER SIGN (Hold 5s: $elapsedSec s / 5.0s)',
            alertMessage: '',
            isConfirmed: false,
            isHolding: true,
            holdProgress: progress,
            holdFeedbackText: 'HOLD ($elapsedSec s / 5.0s): 💧 WATER REQUEST (ASL Sign)',
            holdColor: Colors.blue,
          );
        }
      } else {
        _waterGestureStart = null;
      }
    }

    // -------------------------------------------------------------
    // 4. WASHROOM / TOILET REQUEST (☝️ 1 Finger Only OR Pelvic Sign) - Priority: AMBER
    // -------------------------------------------------------------
    if (!_isCoolingDown(DetectedGesture.washroomRequest, now)) {
      // 1-Finger Raised Sign (Index finger UP, pinky curled down)
      bool oneFingerRaised = false;
      if (rightWrist != null && rightElbow != null && rightWrist.y < rightShoulder.y && rightWrist.y < rightElbow.y) {
        if (rightOneFinger && !rightOpenPalm) {
          oneFingerRaised = true;
        }
      }
      if (leftWrist != null && leftElbow != null && leftWrist.y < leftShoulder.y && leftWrist.y < leftElbow.y) {
        if (leftOneFinger && !leftOpenPalm) {
          oneFingerRaised = true;
        }
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

      // CRITICAL GUARD: If ANY raised hand is an open palm (🖐), fist (✊), water sign, or active emergency/chest/blanket phase, STRICTLY CANCEL washroom!
      if ((rightWrist != null && rightWrist.y < rightShoulder.y && (rightOpenPalm || rightFist || rightWaterSign)) ||
          (leftWrist != null && leftWrist.y < leftShoulder.y && (leftOpenPalm || leftFist || leftWaterSign)) ||
          (_emergencyPhase != "IDLE" || _chestPainPhase != "IDLE" || _blanketGestureStart != null)) {
        oneFingerRaised = false;
        handOnAbdomen = false;
        _washroomGestureStart = null;
      }

      if (oneFingerRaised || handOnAbdomen) {
        _washroomGestureStart ??= now;
        final elapsed = now.difference(_washroomGestureStart!).inMilliseconds;
        final progress = (elapsed / holdDurationMs).clamp(0.0, 1.0);

        if (elapsed >= holdDurationMs) {
          _washroomGestureStart = null;
          _lastTriggered[DetectedGesture.washroomRequest] = now;
          final desc = oneFingerRaised ? '1-finger signal' : 'pelvic sign';
          return GestureResult(
            gesture: DetectedGesture.washroomRequest,
            eventType: 'washroom_request',
            displayTitle: '🚻 WASHROOM ASSISTANCE REQUESTED',
            alertMessage: 'Patient needs toilet / washroom assistance ($desc). Routine care needed.',
            isConfirmed: true,
            holdProgress: 1.0,
          );
        } else {
          final elapsedSec = (elapsed / 1000.0).toStringAsFixed(1);
          final desc = oneFingerRaised ? '☝️ 1 FINGER' : 'PELVIC HAND';
          return GestureResult(
            gesture: DetectedGesture.washroomRequest,
            eventType: 'washroom_request',
            displayTitle: 'HOLDING: Washroom Request ($desc)',
            alertMessage: '',
            isConfirmed: false,
            isHolding: true,
            holdProgress: progress,
            holdFeedbackText: 'HOLD ($elapsedSec s / 3.0s): 🚻 WASHROOM REQUEST ($desc)',
            holdColor: Colors.amber.shade800,
          );
        }
      } else {
        _washroomGestureStart = null;
      }
    }

    // -------------------------------------------------------------
    // 5. BLANKET / COLD (Crossed Hands on Shoulders) - 7s Hold - Priority: TEAL
    // -------------------------------------------------------------
    if (!_isCoolingDown(DetectedGesture.blanketRequest, now)) {
      bool armsCrossedOnShoulders = false;
      if (leftWrist != null && rightWrist != null) {
        final leftOnRightShoulder = _distance(leftWrist.x, leftWrist.y, rightShoulder.x, rightShoulder.y) < shoulderWidth * 0.45;
        final rightOnLeftShoulder = _distance(rightWrist.x, rightWrist.y, leftShoulder.x, leftShoulder.y) < shoulderWidth * 0.45;
        final wristsNearShoulderLevel = (leftWrist.y - rightShoulder.y).abs() < shoulderWidth * 0.40 &&
                                        (rightWrist.y - leftShoulder.y).abs() < shoulderWidth * 0.40;
        if (leftOnRightShoulder && rightOnLeftShoulder && wristsNearShoulderLevel) {
          armsCrossedOnShoulders = true;
        }
      }

      if (armsCrossedOnShoulders) {
        _blanketGestureStart ??= now;
        final elapsed = now.difference(_blanketGestureStart!).inMilliseconds;
        final progress = (elapsed / blanketHoldDurationMs).clamp(0.0, 1.0);

        if (elapsed >= blanketHoldDurationMs) {
          _blanketGestureStart = null;
          _lastTriggered[DetectedGesture.blanketRequest] = now;
          return const GestureResult(
            gesture: DetectedGesture.blanketRequest,
            eventType: 'blanket_request',
            displayTitle: '🛌 BLANKET / COLD ASSISTANCE',
            alertMessage: 'Patient crossed arms with hands on shoulders for 7 seconds (feels cold, blanket requested).',
            isConfirmed: true,
            holdProgress: 1.0,
          );
        } else {
          final elapsedSec = (elapsed / 1000.0).toStringAsFixed(1);
          return GestureResult(
            gesture: DetectedGesture.blanketRequest,
            eventType: 'blanket_request',
            displayTitle: '🛌 BLANKET / COLD (Hold 7s: $elapsedSec s / 7.0s)',
            alertMessage: '',
            isConfirmed: false,
            isHolding: true,
            holdProgress: progress,
            holdFeedbackText: 'HOLD ($elapsedSec s / 7.0s): 🛌 HANDS CROSSED ON SHOULDERS',
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
    _chestPainHoldStart = null;
    _chestPainPhase = "IDLE";
    _chestPainCycles = 0;
    _chestPainPhaseTime = null;
    _chestPainPumpsStartTime = null;
    _chestPainLastHandsNear = null;
    _emergencyCycles = 0;
    _emergencyPhase = "IDLE";
    _emergencyPhaseTime = null;
    _emergencyStartTime = null;
  }

  bool _isCoolingDown(DetectedGesture gesture, DateTime now) {
    final lastTime = _lastTriggered[gesture];
    if (lastTime == null) return false;
    return now.difference(lastTime) < _cooldown;
  }

  double _distance(double x1, double y1, double x2, double y2) {
    return sqrt((x1 - x2) * (x1 - x2) + (y1 - y2) * (y1 - y2));
  }

  bool _isWaterSign(
    PoseLandmark? wrist,
    PoseLandmark? index,
    PoseLandmark? pinky,
    PoseLandmark? thumb,
    double shoulderWidth,
  ) {
    if (wrist == null || index == null) return false;
    final idxUp = index.y < wrist.y - (shoulderWidth * 0.10);
    if (!idxUp) return false;

    // In ASL 'W' / Water sign, thumb and pinky touch or join together
    if (thumb != null && pinky != null) {
      final thumbPinkyDist = _distance(thumb.x, thumb.y, pinky.x, pinky.y);
      if (thumbPinkyDist < shoulderWidth * 0.14) {
        return true;
      }
    }
    return false;
  }

  bool _isOpenPalm(
    PoseLandmark? wrist,
    PoseLandmark? index,
    PoseLandmark? pinky,
    PoseLandmark? thumb,
    double shoulderWidth,
  ) {
    if (wrist == null || index == null) return false;
    final idxUp = index.y < wrist.y - (shoulderWidth * 0.10);
    if (!idxUp) return false;

    // If thumb and pinky are joined, it is water sign, not open palm!
    if (thumb != null && pinky != null) {
      final thumbPinkyDist = _distance(thumb.x, thumb.y, pinky.x, pinky.y);
      if (thumbPinkyDist < shoulderWidth * 0.14) {
        return false;
      }
    }

    if (pinky != null) {
      final pinkyUp = pinky.y < wrist.y - (shoulderWidth * 0.08);
      final span = _distance(index.x, index.y, pinky.x, pinky.y);
      if (pinkyUp && span > (shoulderWidth * 0.15)) {
        return true;
      }
    }
    // If pinky is missing or low confidence, default to open palm so it won't be mistaken for 1-finger
    return true;
  }

  bool _isOneFinger(
    PoseLandmark? wrist,
    PoseLandmark? index,
    PoseLandmark? pinky,
    PoseLandmark? thumb,
    double shoulderWidth,
  ) {
    if (wrist == null || index == null) return false;
    final idxDist = _distance(index.x, index.y, wrist.x, wrist.y);
    final idxUp = index.y < wrist.y - (shoulderWidth * 0.12);
    if (!idxUp) return false;

    // If thumb and pinky are touching, it is ASL water sign, not 1-finger!
    if (thumb != null && pinky != null) {
      final thumbPinkyDist = _distance(thumb.x, thumb.y, pinky.x, pinky.y);
      if (thumbPinkyDist < shoulderWidth * 0.14) {
        return false;
      }
    }

    // To confirm 1-finger (☝️), pinky MUST be visible and folded/curled near wrist
    if (pinky != null) {
      final pinkyDist = _distance(pinky.x, pinky.y, wrist.x, wrist.y);
      final pinkyUp = pinky.y < wrist.y - (shoulderWidth * 0.08);
      final span = _distance(index.x, index.y, pinky.x, pinky.y);

      // If pinky is clearly up and wide span, this is open hand, NOT one finger
      if (pinkyUp && span > (shoulderWidth * 0.15)) {
        return false;
      }

      // One finger: index is up, pinky is curled down
      if (!pinkyUp || pinkyDist < idxDist * 0.65 || span < (shoulderWidth * 0.12)) {
        return true;
      }
    }

    // If pinky is not detected, never assume one finger!
    return false;
  }

  bool _isFist(PoseLandmark? wrist, PoseLandmark? index, PoseLandmark? pinky, double shoulderWidth) {
    if (wrist == null) return false;
    final idxUp = index != null && (index.y < wrist.y - (shoulderWidth * 0.10));
    final pinkyUp = pinky != null && (pinky.y < wrist.y - (shoulderWidth * 0.08));

    // When all fingers are curled/contracted into fist
    if (!idxUp && !pinkyUp) {
      return true;
    }

    if (index != null) {
      final idxDist = _distance(index.x, index.y, wrist.x, wrist.y);
      if (idxDist < shoulderWidth * 0.15) {
        return true;
      }
    }
    return false;
  }
}
