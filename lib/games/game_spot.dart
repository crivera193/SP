import '../map/campus_geography.dart';

// Shared GPS safety and invitation hysteresis; live point radii come from data.
abstract final class ProximitySettings {
  static const entryMeters = 25.0, exitMeters = 40.0, maxAccuracyMeters = 15.0;
  static const maxFixAge = Duration(seconds: 10), dwell = Duration(seconds: 3);
}

class GameSpot {
  const GameSpot({
    required this.id,
    required this.name,
    required this.point,
    this.gameId = 'free-kick',
    this.enabled = true,
    this.attackMeters,
    this.entryMeters = ProximitySettings.entryMeters,
    this.exitMeters = ProximitySettings.exitMeters,
  }) : assert(entryMeters > 0 && exitMeters > entryMeters);
  final String id, name, gameId;
  final CampusPoint point;
  final bool enabled;
  final double entryMeters, exitMeters;
  final double? attackMeters;
}
