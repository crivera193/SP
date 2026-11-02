import 'dart:math' as math;
import '../map/campus_geography.dart';

/// Cosmetic only: never use this position for campus or game eligibility.
/// No extrapolation. A target is reached within 650ms of receipt, using current
/// displayed position and a 160ms time constant rather than chained GPS filters.
class CowboyTravel {
  CampusPoint? position, target;
  DateTime? _timestamp;
  double _age = 0;
  CampusPoint? _candidate;
  DateTime? _candidateSince;
  int _candidateCount = 0;
  bool get awaitingReacquisition => _candidate != null;
  bool get moving =>
      position != null &&
      target != null &&
      CampusGeography.distance(position!, target!) > 0.01;

  bool accept(
    CampusPoint point,
    DateTime timestamp, {
    required double accuracy,
    required bool walking,
  }) {
    if (_timestamp != null && !timestamp.isAfter(_timestamp!)) return false;
    final gap = _timestamp == null
        ? 0
        : timestamp.difference(_timestamp!).inMilliseconds / 1000;
    _timestamp = timestamp;
    if (position == null) {
      position = target =
          point; // Reacquisition, not a guessed intervening route.
    } else if (gap > 8 ||
        CampusGeography.distance(target ?? position!, point) >
            math.max(6.0, math.min(12.0, accuracy * 0.5) + gap * 3)) {
      // One distant reading is not a relocation. Require a small, consistent
      // cluster over time, including when reacquiring after signal loss.
      if (_candidate == null ||
          CampusGeography.distance(_candidate!, point) >
              math.max(2.0, math.min(5.0, accuracy * 0.25))) {
        _candidate = point;
        _candidateSince = timestamp;
        _candidateCount = 1;
      } else {
        _candidateCount++;
      }
      pause();
      if (_candidateCount < 3 ||
          timestamp.difference(_candidateSince!).inMilliseconds < 2000) {
        return false;
      }
      position = target = point;
      _clearCandidate();
    } else if (walking) {
      _clearCandidate();
      target = point;
    } else {
      _clearCandidate();
      pause();
    }
    _age = 0;
    return true;
  }

  bool advance(double seconds, {bool Function(CampusPoint)? contains}) {
    if (!moving || seconds <= 0) return false;
    _age += seconds;
    final a = position!, b = target!;
    final alpha = 1 - math.exp(-seconds / 0.16);
    var next = _age >= 0.65
        ? b
        : CampusPoint(
            a.longitude + (b.longitude - a.longitude) * alpha,
            a.latitude + (b.latitude - a.latitude) * alpha,
          );
    if (CampusGeography.distance(next, b) < 0.01 ||
        (contains != null && !contains(next))) {
      next = b;
    }
    position = next;
    return true;
  }

  void pause() {
    target = position;
    _age = 0;
  }

  void clear() {
    position = target = null;
    _timestamp = null;
    _age = 0;
    _clearCandidate();
  }

  void _clearCandidate() {
    _candidate = null;
    _candidateSince = null;
    _candidateCount = 0;
  }
}
