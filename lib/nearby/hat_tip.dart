import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../teams/game_team.dart';

/// Cached presentation for the already authorized offline Nearby entry.
class HatTipTeams {
  HatTipTeams(this.account);
  final String account;
  String? ownTeamId;
  Map<String, String> colors = const {};

  String get _key => 'sp_bsvcnndqvjizxgnxhxkd_hat_teams_v1_$account';

  Future<void> save(GameTeam team, List<GameTeam> catalog) async {
    ownTeamId = team.id;
    colors = {for (final team in catalog) team.id: team.colorName};
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _key,
      jsonEncode({'team': ownTeamId, 'colors': colors}),
    );
  }

  Future<void> load() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_key);
    if (raw == null) return;
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final cached = Map<String, String>.from(data['colors'] as Map);
    final team = data['team'] as String;
    if (cached.containsKey(team)) {
      ownTeamId = team;
      colors = cached;
    }
  }
}

/// A signal-strength filter for an approximate range, never a distance reading.
class HatTipSignal {
  static const freshness = Duration(seconds: 5);
  // Initial threshold for the two-phone calibration.
  static const minimumDbm = -65;
  final _samples = <(DateTime, int)>[];

  void observe(DateTime at, int? strength) {
    if (strength == null ||
        (_samples.isNotEmpty && !at.isAfter(_samples.last.$1))) {
      return;
    }
    _samples.add((at, strength));
    if (_samples.length > 7) _samples.removeAt(0);
  }

  int? median(DateTime now) {
    final strengths =
        _samples
            .where(
              (sample) =>
                  !sample.$1.isAfter(now) &&
                  now.difference(sample.$1) <= freshness,
            )
            .map((sample) => sample.$2)
            .toList()
          ..sort();
    return strengths.length >= 3 ? strengths[strengths.length ~/ 2] : null;
  }

  bool isClose(DateTime now) => (median(now) ?? -128) >= minimumDbm;
}

class HatTipTarget {
  const HatTipTarget(this.session, this.colorName);
  final String session, colorName;
}
