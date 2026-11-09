import 'team_fixtures.dart';
import 'dart:async';
import 'package:campus_app/teams/game_team.dart';
import 'package:campus_app/teams/team_membership.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryTeams implements TeamRepository {
  GameTeam? saved;
  bool loadFails = false, saveFails = false, commitThenTimeout = false;
  List<GameTeam> choices = testTeams;
  int writes = 0;
  Completer<GameTeam>? pending;
  @override
  Future<TeamSnapshot> load() async {
    if (loadFails) throw TimeoutException('offline');
    return TeamSnapshot(choices: choices, team: saved);
  }

  @override
  Future<GameTeam> choose(GameTeam team) async {
    writes++;
    if (saveFails) throw TimeoutException('offline');
    if (pending != null) return pending!.future;
    saved ??= team;
    if (commitThenTimeout) throw TimeoutException('response lost');
    return saved!;
  }
}

void main() {
  test('query errors never become missing membership', () async {
    final repo = MemoryTeams()..loadFails = true;
    final state = TeamMembership(repo);
    await state.load();
    expect(state.phase, TeamPhase.error);
    await state.choose(artStuff);
    expect(repo.writes, 0);
    repo.loadFails = false;
    await state.load();
    expect(state.phase, TeamPhase.missing);
    state.dispose();
  });
  test(
    'failed save stays gated; retry reconciles authoritative winner',
    () async {
      final repo = MemoryTeams()..saveFails = true;
      final state = TeamMembership(repo);
      await state.load();
      await state.choose(artStuff);
      expect(state.phase, TeamPhase.missing);
      expect(state.team, isNull);
      repo.saved = mathEngineering; // Another device completed first.
      await state.choose(artStuff);
      expect(state.team, mathEngineering);
      expect(repo.writes, 1);
      state.dispose();
    },
  );
  test(
    'lost response rereads membership and confirms committed choice',
    () async {
      final repo = MemoryTeams()..commitThenTimeout = true;
      final state = TeamMembership(repo);
      await state.load();
      await state.choose(healthScience);
      expect(state.phase, TeamPhase.assigned);
      expect(state.team, healthScience);
      state.dispose();
    },
  );
  test(
    'duplicate confirmation and late response after account switch ignored',
    () async {
      final repo = MemoryTeams()..pending = Completer<GameTeam>();
      final first = TeamMembership(repo);
      await first.load();
      final save = first.choose(artStuff);
      await Future<void>.delayed(Duration.zero);
      await first.choose(mathEngineering);
      expect(repo.writes, 1);
      first.dispose();
      final second = TeamMembership(MemoryTeams());
      await second.load();
      repo.pending!.complete(artStuff);
      await save;
      expect(second.phase, TeamPhase.missing);
      expect(second.team, isNull);
      second.dispose();
    },
  );
  test('restart and a second client read the same stored membership', () async {
    final repo = MemoryTeams();
    final first = TeamMembership(repo);
    await first.load();
    await first.choose(artStuff);
    first.dispose();
    final another = TeamMembership(repo);
    await another.load();
    expect(another.phase, TeamPhase.assigned);
    expect(another.team, artStuff);
    another.dispose();
  });
  test(
    'empty catalog blocks selection but preserves existing membership',
    () async {
      final repo = MemoryTeams()..choices = [];
      final state = TeamMembership(repo);
      await state.load();
      expect(state.phase, TeamPhase.error);
      await state.choose(artStuff);
      expect(repo.writes, 0);
      repo.saved = artStuff;
      await state.load();
      expect(state.phase, TeamPhase.assigned);
      state.dispose();
    },
  );
  test('catalog validates colors and duplicate IDs', () {
    final row = {
      'id': 'new',
      'display_name': 'New team',
      'color_name': 'Green',
      'color_hex': '#22aa44',
      'description': 'New server content',
    };
    expect(GameTeam.fromJson(row).id, 'new');
    expect(
      () => GameTeam.fromJson({...row, 'color_hex': 'invalid'}),
      throwsFormatException,
    );
    expect(
      () => TeamSnapshot.fromJson({
        'choices': [row, row],
        'team': null,
      }),
      throwsFormatException,
    );
  });
}
