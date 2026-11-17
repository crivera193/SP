import 'package:flutter/foundation.dart';
import '../games/game_spot.dart';
import '../map/campus_geography.dart';
import '../teams/game_team.dart';

/// Adapted from GOTest's live point catalog; SP owns the schema and team data.
@immutable
class QuizLocation extends GameSpot {
  QuizLocation.fromJson(Map<String, dynamic> j)
    : description = j['description'] as String,
      animation = j['animation'] as String,
      artOffsets = List.unmodifiable(
        (j['art_offsets'] as List).map(
          (o) => CampusPoint(
            (o['longitude'] as num).toDouble(),
            (o['latitude'] as num).toDouble(),
          ),
        ),
      ),
      owner = j['owner'] == null
          ? null
          : GameTeam.fromJson(Map<String, dynamic>.from(j['owner'] as Map)),
      scores = List.unmodifiable(
        (j['scores'] as List).map(
          (s) => TeamScore.fromJson(Map<String, dynamic>.from(s as Map)),
        ),
      ),
      revision = j['revision'] as int,
      super(
        id: j['id'] as String,
        name: j['name'] as String,
        point: CampusPoint(
          (j['longitude'] as num).toDouble(),
          (j['latitude'] as num).toDouble(),
        ),
        gameId: 'quiz',
        enabled: j['enabled'] as bool,
        entryMeters: (j['entry_meters'] as num).toDouble(),
        exitMeters: (j['exit_meters'] as num).toDouble(),
        attackMeters: (j['entry_meters'] as num).toDouble(),
      ) {
    if (id.isEmpty ||
        name.trim().isEmpty ||
        !point.latitude.isFinite ||
        point.latitude.abs() > 90 ||
        !point.longitude.isFinite ||
        point.longitude.abs() > 180 ||
        !entryMeters.isFinite ||
        !exitMeters.isFinite ||
        entryMeters <= 0 ||
        exitMeters <= entryMeters ||
        !const {'horse', 'plant', 'cats'}.contains(animation) ||
        artOffsets.isEmpty ||
        artOffsets.length > 8 ||
        artOffsets.any(
          (o) =>
              !o.longitude.isFinite ||
              !o.latitude.isFinite ||
              o.longitude.abs() > .001 ||
              o.latitude.abs() > .001,
        )) {
      throw const FormatException('Invalid quiz location.');
    }
  }
  final String description, animation;
  final GameTeam? owner;
  final List<TeamScore> scores;
  final int revision;
  final List<CampusPoint> artOffsets;
  List<CampusPoint> get markerPoints => [
    for (final o in artOffsets)
      CampusPoint(point.longitude + o.longitude, point.latitude + o.latitude),
  ];
}

class TeamScore {
  TeamScore.fromJson(Map<String, dynamic> j)
    : team = GameTeam.fromJson(Map<String, dynamic>.from(j['team'] as Map)),
      correct = j['correct'] as int {
    if (correct < 0) throw const FormatException('Invalid quiz score.');
  }
  final GameTeam team;
  final int correct;
}

class QuizAttempt {
  QuizAttempt.fromJson(Map<String, dynamic> j)
    : id = j['id'] as String,
      prompt = j['prompt'] as String,
      status = j['status'] as String,
      correct = j['correct'] as bool?,
      selected = j['selected'] as bool?,
      serverNow = DateTime.parse(j['server_now'] as String),
      retryAt = j['retry_at'] == null
          ? null
          : DateTime.parse(j['retry_at'] as String),
      location = QuizLocation.fromJson(
        Map<String, dynamic>.from(j['location'] as Map),
      );
  final String id, prompt, status;
  final bool? correct, selected;
  final DateTime serverNow;
  final DateTime? retryAt;
  final QuizLocation location;
  bool get answered => status == 'answered';
  bool get active => status == 'active';
}
