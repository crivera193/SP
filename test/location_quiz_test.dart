import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:campus_app/map/campus_fix.dart';
import 'package:campus_app/map/campus_geography.dart';
import 'package:campus_app/games/spot_proximity.dart';
import 'package:campus_app/quizzes/quiz_models.dart';
import 'package:campus_app/quizzes/quiz_repository.dart';
import 'package:campus_app/quizzes/quiz_session.dart';
import 'package:campus_app/quizzes/quiz_screen.dart';
import 'package:campus_app/quizzes/quiz_markers.dart';

Map<String, dynamic> team(String id, String color) => {
  'id': id,
  'display_name': id,
  'color_name': id,
  'color_hex': color,
  'description': 'Fixture team',
};
Map<String, dynamic> location({
  String id = 'horse',
  String animation = 'horse',
  String? owner,
  int? points,
  int revision = 0,
}) => {
  'id': id,
  'name': id == 'horse' ? 'Bronco Point' : id,
  'description': 'Stop on a safe outdoor path to answer.',
  'longitude': 0.0,
  'latitude': 0.0,
  'entry_meters': 25,
  'exit_meters': 40,
  'animation': animation,
  'art_offsets': [
    {'longitude': 0, 'latitude': 0},
  ],
  'enabled': true,
  'revision': revision,
  'owner': owner == null
      ? null
      : team(owner, owner == 'Blue' ? '#77bfff' : '#ff9292'),
  'scores': [
    {
      'team': team('Blue', '#77bfff'),
      'correct': owner == 'Blue' ? 1 : 0,
      'points': owner == 'Blue' ? (points ?? 1) : 0,
    },
    {
      'team': team('Red', '#ff9292'),
      'correct': owner == 'Red' ? 1 : 0,
      'points': owner == 'Red' ? (points ?? 1) : 0,
    },
  ],
};
QuizAttempt attempt({
  bool answered = false,
  int revision = 0,
  int award = 1,
  int level = 1,
}) => QuizAttempt.fromJson({
  'id': 'attempt',
  'prompt': 'Question:True or False',
  'status': answered ? 'answered' : 'active',
  'correct': answered ? true : null,
  'selected': answered ? true : null,
  'awarded_points': answered ? award : null,
  'reward_level': answered ? level : null,
  'server_now': DateTime.utc(2026).toIso8601String(),
  'retry_at': answered
      ? DateTime.utc(2026).add(const Duration(minutes: 10)).toIso8601String()
      : null,
  'location': location(
    owner: answered ? 'Blue' : null,
    revision: revision,
    points: award,
  ),
});

class QuizTransport implements QuizRepository {
  List<QuizLocation> rows = [QuizLocation.fromJson(location())];
  bool loseResponse = false;
  int award = 1, level = 1;
  Completer<List<QuizLocation>>? loading;
  final commands = <String>[];
  final choices = <bool>[];
  @override
  Future<List<QuizLocation>> catalog() async => loading?.future ?? rows;
  @override
  Future<QuizAttempt> begin(
    String location,
    String request,
    CampusFix fix,
  ) async => attempt();
  @override
  Future<QuizAttempt> answer(
    String attemptId,
    String command,
    bool choice,
    CampusFix fix,
  ) async {
    commands.add(command);
    choices.add(choice);
    if (loseResponse) {
      loseResponse = false;
      throw TimeoutException('response lost');
    }
    return attempt(answered: true, revision: 1, award: award, level: level);
  }
}

final fix = CampusFix(const CampusPoint(0, 0), 3, DateTime.utc(2026));
Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
  await tester.pump();
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('output/quizzes/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final loader = FontLoader('Inter')
      ..addFont(rootBundle.load('assets/fonts/Inter-Variable.ttf'));
    await loader.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  test(
    'lost answer response retries exactly the same command and choice',
    () async {
      final repo = QuizTransport()..loseResponse = true;
      final live = QuizCatalog(repo);
      await live.load();
      final s = QuizSession(live, 'horse', () => fix, () => null);
      await s.load();
      await s.answer(true);
      expect(s.retryPending, true);
      expect(s.attempt!.answered, false);
      await s.answer(false);
      expect(repo.commands, hasLength(1));
      await s.retry();
      expect(repo.commands[0], repo.commands[1]);
      expect(repo.choices, [true, true]);
      expect(s.attempt!.answered, true);
      expect(s.cooldownSeconds, inInclusiveRange(599, 600));
      expect(live.find('horse')!.owner!.id, 'Blue');
      s.dispose();
      live.dispose();
    },
  );
  test(
    'delayed catalog read cannot undo a newer answer revision; disable removes location',
    () async {
      final repo = QuizTransport();
      final live = QuizCatalog(repo);
      await live.load();
      repo.loading = Completer();
      final pending = live.load();
      live.apply(QuizLocation.fromJson(location(owner: 'Blue', revision: 2)));
      repo.loading!.complete([QuizLocation.fromJson(location())]);
      await pending;
      expect(live.find('horse')!.owner!.id, 'Blue');
      repo.loading = null;
      repo.rows = [];
      await live.load();
      expect(live.find('horse'), null);
      live.dispose();
    },
  );
  test(
    'GPS transitions reveal each location independently and dismiss never toggles artwork',
    () {
      final a = QuizLocation.fromJson(location()),
          b = QuizLocation.fromJson({
            ...location(id: 'plant', animation: 'plant'),
            'longitude': .001,
          });
      final proximity = SpotProximity([a, b]);
      final start = DateTime.utc(2026);
      void update(int t, double longitude) {
        final at = start.add(Duration(seconds: t));
        proximity.accept(
          CampusFix(CampusPoint(longitude, 0), 3, at),
          onCampus: true,
          now: at,
        );
      }

      update(0, 0);
      update(3, 0);
      expect(proximity.revealedSpots(start.add(const Duration(seconds: 3))), {
        'horse',
      });
      proximity.dismiss();
      expect(proximity.revealedSpots(start.add(const Duration(seconds: 3))), {
        'horse',
      });
      update(4, .001);
      update(7, .001);
      expect(proximity.revealedSpots(start.add(const Duration(seconds: 7))), {
        'plant',
      });
      expect(
        proximity.revealedSpots(start.add(const Duration(seconds: 20))),
        isEmpty,
      );
    },
  );
  testWidgets(
    'direct True/False quiz, saved result, cooldown and phone layout',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = QuizTransport();
      final live = QuizCatalog(repo);
      await live.load();
      final session = QuizSession(live, 'horse', () => fix, () => null);
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            useMaterial3: true,
            fontFamily: 'Inter',
            colorSchemeSeed: const Color(0xff123d2b),
          ),
          home: RepaintBoundary(
            key: key,
            child: QuizScreen(session: session),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('A. True'), findsOneWidget);
      expect(find.text('B. False'), findsOneWidget);
      await capture(tester, key, 'question-first-390x844');
      await tester.tap(find.byKey(const ValueKey('quiz-true')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.text('Correct! 1 point saved for your team.'),
        findsOneWidget,
      );
      expect(find.textContaining('Next quiz in'), findsOneWidget);
      await capture(tester, key, 'score-bars-saved-390x844');
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
      live.dispose();
    },
  );
  testWidgets(
    'server-awarded two-point receipt drives the result and team chart',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = QuizTransport()
        ..award = 2
        ..level = 10;
      final catalog = QuizCatalog(repo);
      await catalog.load();
      final session = QuizSession(catalog, 'horse', () => fix, () => null);
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            useMaterial3: true,
            fontFamily: 'Inter',
            colorSchemeSeed: const Color(0xff123d2b),
          ),
          home: RepaintBoundary(
            key: key,
            child: QuizScreen(session: session),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('quiz-true')));
      await tester.pump();
      expect(
        find.text('Correct! 2 points saved for your team.'),
        findsOneWidget,
      );
      expect(find.text('2 points'), findsOneWidget);
      expect(session.attempt!.rewardLevel, 10);
      expect(session.location!.scores.first.correct, 1);
      expect(session.location!.scores.first.points, 2);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const ValueKey('quiz-score-Blue')),
            )
            .value,
        1,
      );
      expect(tester.takeException(), isNull);
      await capture(tester, key, 'weighted-score-390x844');
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
      catalog.dispose();
    },
  );
  testWidgets(
    'outside proximity shows one GPS notice and keeps retry available',
    (tester) async {
      final catalog = QuizCatalog(QuizTransport());
      await catalog.load();
      const reason = 'A fresh GPS position is required.';
      final session = QuizSession(catalog, 'horse', () => null, () => reason);
      await tester.pumpWidget(MaterialApp(home: QuizScreen(session: session)));
      await tester.pump();
      expect(find.text(reason), findsOneWidget);
      expect(find.text('Retry quiz'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
      catalog.dispose();
    },
  );
  testWidgets('GPS loss disables quiz answers without revealing a result', (
    tester,
  ) async {
    final repo = QuizTransport(), catalog = QuizCatalog(repo);
    await catalog.load();
    String? reason;
    final session = QuizSession(
      catalog,
      'horse',
      () => reason == null ? fix : null,
      () => reason,
    );
    await tester.pumpWidget(MaterialApp(home: QuizScreen(session: session)));
    await tester.pump();
    reason = 'A fresh GPS position is required.';
    await tester.pump(const Duration(seconds: 1));
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('quiz-true')))
          .onPressed,
      null,
    );
    expect(repo.commands, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
    catalog.dispose();
  });
  testWidgets(
    'landmark Lotties switch by proximity, keep team colors and handle taps',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final duck = QuizLocation.fromJson({
        ...location(id: 'eieab', animation: 'duck', owner: 'Red'),
        'name': 'Computer Science (EIEAB)',
        'latitude': 26.30637471,
        'longitude': -98.17457576,
      });
      final proximity = SpotProximity([duck]);
      final start = DateTime.utc(2026);
      var now = start;
      void updateDuckFix(int seconds, CampusPoint point) {
        now = start.add(Duration(seconds: seconds));
        proximity.accept(CampusFix(point, 3, now), onCampus: true, now: now);
      }

      final locations = [
        QuizLocation.fromJson(location(owner: 'Blue')),
        QuizLocation.fromJson(
          location(id: 'plant', animation: 'plant', owner: 'Red'),
        ),
        QuizLocation.fromJson(
          location(id: 'cats', animation: 'cats', owner: 'Blue'),
        ),
        duck,
      ];
      final positions = {
        'horse': const Offset(100, 220),
        'horse#0': const Offset(100, 220),
        'plant': const Offset(290, 220),
        'plant#0': const Offset(290, 220),
        'cats': const Offset(195, 430),
        'cats#0': const Offset(195, 430),
        'eieab': const Offset(195, 600),
        'eieab#0': const Offset(195, 600),
      };
      final key = GlobalKey();
      final opened = <String>[];
      var canOpen = true;
      Future<void> render(Set<String> revealed) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: RepaintBoundary(
                key: key,
                child: ColoredBox(
                  color: const Color(0xffc9ddd3),
                  child: QuizMarkers(
                    locations: locations,
                    positions: positions,
                    revealed: {...revealed, ...proximity.revealedSpots(now)},
                    canOpen: (point) => point.id == duck.id
                        ? proximity.attackReason(point, now) == null
                        : canOpen,
                    onOpen: (point) => opened.add(point.id),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pump(const Duration(milliseconds: 400));
      }

      await render({});
      expect(find.byKey(const ValueKey('horse:diamond')), findsOneWidget);
      final duckDiamond = find.byKey(const ValueKey('eieab:diamond'));
      final duckMarker = find.byKey(const ValueKey('eieab:0'));
      expect(duckDiamond, findsOneWidget);
      expect(
        tester
            .widget<TeamLottie>(
              find.descendant(
                of: duckDiamond,
                matching: find.byType(TeamLottie),
              ),
            )
            .color,
        duck.owner!.color,
      );
      await capture(tester, key, 'diamonds-390x844');
      await tester.tap(find.byKey(const ValueKey('horse:diamond')));
      await tester.tap(duckDiamond);
      expect(opened, isEmpty, reason: 'outside proximity cannot open a quiz');
      expect(
        find.byKey(const ValueKey('horse:diamond')),
        findsOneWidget,
        reason: 'tap never reveals animation',
      );
      await render({'horse', 'plant', 'cats'});
      expect(find.byKey(const ValueKey('horse:0')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('horse:0')));
      expect(opened, ['horse']);
      canOpen = false;
      await render({'horse', 'plant', 'cats'});
      await tester.tap(find.byKey(const ValueKey('horse:0')));
      expect(opened, [
        'horse',
      ], reason: 'lost eligibility blocks even a revealed marker');
      canOpen = true;
      updateDuckFix(0, duck.point);
      await render({'horse', 'plant', 'cats'});
      expect(duckDiamond, findsOneWidget);
      updateDuckFix(3, duck.point);
      await render({'horse', 'plant', 'cats'});
      expect(duckDiamond, findsNothing);
      expect(duckMarker, findsOneWidget);
      expect(
        tester
            .widget<TeamLottie>(
              find.byKey(
                const ValueKey('assets/animations/animals/walking-duck.json'),
              ),
            )
            .color,
        duck.owner!.color,
      );
      await tester.tap(duckMarker);
      expect(opened, ['horse', 'eieab']);
      expect(
        tester
            .widget<TeamLottie>(
              find.byKey(
                const ValueKey('assets/animations/animals/stallion.json'),
              ),
            )
            .color,
        const Color(0xff77bfff),
      );
      await capture(tester, key, 'animations-390x844');
      await tester.pump(const Duration(milliseconds: 500));
      await capture(tester, key, 'animations-midframe-390x844');
      locations[0] = QuizLocation.fromJson(location(owner: 'Red', revision: 2));
      await render({'horse', 'plant', 'cats'});
      await capture(tester, key, 'owner-changed-390x844');
      locations[0] = QuizLocation.fromJson(location(revision: 3));
      await render({'horse', 'plant', 'cats'});
      await capture(tester, key, 'unclaimed-390x844');
      final outside = CampusPoint(
        duck.point.longitude + .001,
        duck.point.latitude,
      );
      updateDuckFix(4, outside);
      await render({});
      expect(duckMarker, findsOneWidget);
      await tester.tap(duckMarker);
      expect(opened, ['horse', 'eieab'], reason: 'tap rechecks entry distance');
      updateDuckFix(7, outside);
      await render({});
      expect(duckDiamond, findsOneWidget);
      expect(duckMarker, findsNothing);
      expect(find.byKey(const ValueKey('horse:diamond')), findsOneWidget);
      expect(find.byKey(const ValueKey('horse:0')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('horse:diamond')));
      await tester.tap(duckDiamond);
      expect(opened, ['horse', 'eieab'], reason: 'departure restores diamonds');
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
