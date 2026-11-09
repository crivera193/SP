import 'package:flutter/material.dart';

/// Server-owned presentation; membership uses the stable ID, never its label.
@immutable
class GameTeam {
  const GameTeam({
    required this.id,
    required this.displayName,
    required this.colorName,
    required this.color,
    required this.description,
  });
  final String id, displayName, colorName, description;
  final Color color;

  factory GameTeam.fromJson(Map<String, dynamic> json) {
    String text(String key) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('Invalid team $key.');
      }
      return value;
    }

    final hex = text('color_hex');
    if (!RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(hex)) {
      throw const FormatException('Invalid team color.');
    }
    return GameTeam(
      id: text('id'),
      displayName: text('display_name'),
      colorName: text('color_name'),
      description: text('description'),
      color: Color(0xff000000 | int.parse(hex.substring(1), radix: 16)),
    );
  }
}

class TeamSnapshot {
  TeamSnapshot({required List<GameTeam> choices, this.team})
    : choices = List.unmodifiable(choices);
  final List<GameTeam> choices;
  final GameTeam? team;

  factory TeamSnapshot.fromJson(Map<String, dynamic> json) {
    final choices = (json['choices'] as List)
        .map((row) => GameTeam.fromJson(Map<String, dynamic>.from(row as Map)))
        .toList();
    if (choices.map((team) => team.id).toSet().length != choices.length) {
      throw const FormatException('Duplicate team IDs.');
    }
    final saved = json['team'];
    return TeamSnapshot(
      choices: choices,
      team: saved == null
          ? null
          : GameTeam.fromJson(Map<String, dynamic>.from(saved as Map)),
    );
  }
}
