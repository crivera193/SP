import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'game_team.dart';

abstract interface class TeamRepository {
  Future<TeamSnapshot> load();
  Future<GameTeam> choose(GameTeam team);
}

class SupabaseTeamRepository implements TeamRepository {
  SupabaseTeamRepository(this.client, this.userId);
  final SupabaseClient client;
  final String userId;

  void _checkAccount() {
    if (client.auth.currentUser?.id != userId) {
      throw StateError('Account changed. Sign in again.');
    }
  }

  @override
  Future<TeamSnapshot> load() async {
    _checkAccount();
    final result = await client
        .rpc('sp_teams_read')
        .timeout(const Duration(seconds: 15));
    _checkAccount();
    return TeamSnapshot.fromJson(Map<String, dynamic>.from(result as Map));
  }

  @override
  Future<GameTeam> choose(GameTeam team) async {
    _checkAccount();
    final id = await client
        .rpc('sp_teams_choose', params: {'requested_team': team.id})
        .timeout(const Duration(seconds: 15));
    _checkAccount();
    return GameTeam.fromJson(Map<String, dynamic>.from(id as Map));
  }
}

enum TeamPhase { loading, missing, saving, assigned, error }

/// One instance per authenticated account. No device flag or persisted cache.
class TeamMembership extends ChangeNotifier {
  TeamMembership(this.repository);
  final TeamRepository repository;
  TeamPhase phase = TeamPhase.loading;
  GameTeam? team;
  List<GameTeam> choices = const [];
  String? message;
  bool _disposed = false;
  int _generation = 0;

  bool get busy => phase == TeamPhase.loading || phase == TeamPhase.saving;

  Future<void> load() async {
    if (_disposed || phase == TeamPhase.saving) return;
    final generation = ++_generation;
    phase = TeamPhase.loading;
    team = null;
    message = null;
    notifyListeners();
    try {
      final saved = await repository.load();
      if (_disposed || generation != _generation) return;
      _accept(saved);
    } catch (_) {
      if (_disposed || generation != _generation) return;
      phase = TeamPhase.error;
      message =
          'Your team could not be checked. Check your connection and retry.';
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> choose(GameTeam choice) async {
    if (_disposed || phase != TeamPhase.missing) return;
    final generation = ++_generation;
    phase = TeamPhase.saving;
    message = null;
    notifyListeners();
    try {
      // Always reread before a retry; the previous request may have committed.
      final existing = await repository.load();
      if (_disposed || generation != _generation) return;
      choices = existing.choices;
      final saved = existing.team ?? await repository.choose(choice);
      if (_disposed || generation != _generation) return;
      team =
          saved; // RPC returns the winner, even if another device chose first.
      phase = TeamPhase.assigned;
    } catch (_) {
      if (_disposed || generation != _generation) return;
      try {
        final saved = await repository.load();
        if (_disposed || generation != _generation) return;
        _accept(saved);
        message = saved.team == null
            ? 'Your choice was not saved. Check your connection and try again.'
            : null;
      } catch (_) {
        if (_disposed || generation != _generation) return;
        phase = TeamPhase.error;
        message =
            'We could not confirm whether your choice saved. Retry the team check before choosing again.';
      }
    }
    if (!_disposed) notifyListeners();
  }

  void _accept(TeamSnapshot snapshot) {
    choices = snapshot.choices;
    team = snapshot.team;
    phase = team != null
        ? TeamPhase.assigned
        : choices.isEmpty
        ? TeamPhase.error
        : TeamPhase.missing;
    if (choices.isEmpty && team == null) {
      message = 'No teams are available right now. Retry the team check later.';
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    team = null;
    super.dispose();
  }
}

/// The app uses owned ChangeNotifiers/StatefulWidgets; retain that architecture.
class TeamScope extends InheritedNotifier<TeamMembership> {
  const TeamScope({
    super.key,
    required TeamMembership membership,
    required super.child,
  }) : super(notifier: membership);
  static TeamMembership of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TeamScope>()!.notifier!;
}
