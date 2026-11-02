import 'dart:math' as math;

/// GPS evidence only. Cosmetic interpolation and camera motion never enter here.
class CowboyMotion {
  double heading = 0, playbackRate = 1, speed = 0;
  double cadenceSeconds = 1;
  bool walking = false;
  _MotionFix? _anchor, _previous;
  DateTime? _lastMovement;
  int _credibleSegments = 0;
  double _stationarySeconds = 0, _threshold = 1.8;
  final List<_MotionFix> _recent = [];
  _MotionFix? _lowSpeedAnchor;

  void accept({
    required double longitude,
    required double latitude,
    required double accuracy,
    required DateTime timestamp,
    required DateTime now,
    required bool onCampus,
    double? measuredSpeed,
    double? speedAccuracy,
  }) {
    if (_previous != null && !timestamp.isAfter(_previous!.time)) return;
    if (!onCampus ||
        !accuracy.isFinite ||
        accuracy < 0 ||
        accuracy > 40 ||
        !latitude.isFinite ||
        !longitude.isFinite ||
        latitude.abs() > 90 ||
        longitude.abs() > 180 ||
        now.difference(timestamp).inMilliseconds > 6000 ||
        timestamp.isAfter(now.add(const Duration(seconds: 2)))) {
      stop();
      return;
    }
    final fix = _MotionFix(longitude, latitude, accuracy, timestamp);
    final previous = _previous;
    var interval = 0.0;
    if (previous != null) {
      interval = timestamp.difference(previous.time).inMilliseconds / 1000;
      if (interval > 8) {
        stop();
      } else {
        cadenceSeconds = (cadenceSeconds * 0.5 + interval * 0.5).clamp(0.5, 6);
      }
    }
    _recent.add(fix);
    _recent.removeWhere(
      (p) => timestamp.difference(p.time).inMilliseconds > 3000,
    );
    if (_recent.length > 32) _recent.removeAt(0);
    final windowSeconds =
        timestamp.difference(_recent.first.time).inMilliseconds / 1000;
    final net = _distance(_recent.first, fix);
    var path = 0.0;
    for (var i = 1; i < _recent.length; i++) {
      path += _distance(_recent[i - 1], _recent[i]);
    }
    // A short coherent progression can be slow walking. Back-and-forth GPS
    // noise should not count as sustained motion just because each step is big.
    final progressing =
        windowSeconds >= 2 &&
        net >= 0.8 &&
        net / windowSeconds >= 0.25 &&
        path > 0 &&
        net / path >= 0.65;
    _previous = fix;
    final anchor = _anchor;
    _anchor ??= fix;
    if (anchor == null) return;
    final seconds = timestamp.difference(anchor.time).inMilliseconds / 1000;
    final east =
        (longitude - anchor.lon) * 111320 * math.cos(latitude * math.pi / 180);
    final north = (latitude - anchor.lat) * 111320;
    final distance = math.sqrt(east * east + north * north);
    final hasSpeed =
        measuredSpeed != null &&
        measuredSpeed.isFinite &&
        measuredSpeed >= 0 &&
        speedAccuracy != null &&
        speedAccuracy.isFinite &&
        speedAccuracy >= 0 &&
        speedAccuracy <= 0.8;
    _threshold = math.max(
      1.8,
      math.min(3.5, math.max(accuracy, anchor.accuracy) * 0.15),
    );
    final measuredStill = hasSpeed && measuredSpeed + speedAccuracy <= 0.45;
    if (measuredStill) {
      _lowSpeedAnchor ??= fix;
    } else {
      _lowSpeedAnchor = null;
    }
    // A stuck provider speed must not veto a sustained, substantial real walk.
    final contradictsStill =
        progressing &&
        _lowSpeedAnchor != null &&
        timestamp.difference(_lowSpeedAnchor!.time).inMilliseconds >= 3000 &&
        _distance(_lowSpeedAnchor!, fix) >=
            math.max(3.5, math.min(8.0, accuracy * 0.5));
    final positionStill =
        windowSeconds >= 2 &&
        !progressing &&
        net <= math.max(1.0, math.min(2.0, accuracy * 0.1));
    final stillEvidence = (measuredStill && !contradictsStill) || positionStill;
    _stationarySeconds = stillEvidence
        ? _stationarySeconds + interval.clamp(0.0, 3.0)
        : 0;
    if (_stationarySeconds >= 2.0) {
      _idle();
      _anchor = fix;
      return;
    }
    if (seconds <= 0) return;
    if (seconds > 16) {
      _anchor = fix;
      _idle();
      return;
    }
    if (distance < _threshold) {
      if (walking && progressing && (!measuredStill || contradictsStill)) {
        _lastMovement = timestamp;
      }
      expire(now);
      return;
    }
    _anchor = fix;
    final derivedSpeed = distance / seconds;
    // GPS displacement owns movement and course. Simulator/provider velocity
    // can lag behind a mode/route change; use it only to corroborate movement.
    final corroborated =
        hasSpeed &&
        (measuredSpeed - derivedSpeed).abs() <=
            math.max(1.0, speedAccuracy * 2);
    final travelSpeed = derivedSpeed;
    // The cartographic player walks during credible travel, including a route
    // replay above human walking pace. Clip speed stays capped below; a modest
    // emulator route must not freeze both gait and facing. Jumps still reject.
    if (travelSpeed < 0.25 ||
        travelSpeed > 12 ||
        seconds < 0.5 ||
        (windowSeconds >= 2 && !progressing)) {
      _idle();
      return;
    }
    final nextHeading = (math.atan2(east, north) * 180 / math.pi + 360) % 360;
    final delta = ((nextHeading - heading + 540) % 360) - 180;
    if (!walking && _credibleSegments > 0 && delta.abs() > 100) {
      _credibleSegments = 0;
    }
    heading = nextHeading;
    _credibleSegments++;
    walking =
        _credibleSegments >= 2 ||
        (corroborated && measuredSpeed >= 0.5) ||
        (progressing && windowSeconds >= 3 && !measuredStill);
    _lastMovement = timestamp;
    speed = travelSpeed;
    playbackRate = (speed / 1.0645109415).clamp(0.8, 1.35);
  }

  void expire(DateTime now) {
    if (_previous == null) return;
    // Evidence accumulation is not expired by the shorter walking hold timer.
    // Otherwise a 4-6s threshold crossing can never form two segments.
    final missingLimit = (cadenceSeconds * 2.2).clamp(3.0, 8.0);
    if (now.difference(_previous!.time).inMilliseconds / 1000 > missingLimit) {
      _idle();
      _anchor = null;
      return;
    }
    final movementHold =
        (_threshold / math.max(speed, 0.6) + cadenceSeconds * 1.5).clamp(
          3.2,
          7.0,
        );
    if (walking &&
        _lastMovement != null &&
        now.difference(_lastMovement!).inMilliseconds / 1000 > movementHold) {
      _idle();
    }
  }

  void _idle() {
    walking = false;
    _credibleSegments = 0;
    _lastMovement = null;
    speed = 0;
  }

  void stop() {
    _idle();
    _anchor = null;
    _previous = null;
    _stationarySeconds = 0;
    cadenceSeconds = 1;
    _recent.clear();
    _lowSpeedAnchor = null;
  }

  static double _distance(_MotionFix a, _MotionFix b) {
    final x = (a.lon - b.lon) * 111320 * math.cos(a.lat * math.pi / 180),
        y = (a.lat - b.lat) * 111320;
    return math.sqrt(x * x + y * y);
  }
}

class _MotionFix {
  _MotionFix(this.lon, this.lat, this.accuracy, this.time);
  final double lon, lat, accuracy;
  final DateTime time;
}
