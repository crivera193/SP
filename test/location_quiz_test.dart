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
    {'team': team('Blue', '#77bfff'), 'correct': owner == 'Blue' ? 1 : 0},
    {'team': team('Red', '#ff9292'), 'correct': owner == 'Red' ? 1 : 0},
  ],
};
QuizAttempt attempt({bool answered = false, int revision = 0}) =>
    QuizAttempt.fromJson({
      'id': 'attempt',
      'prompt': 'Question:True or False',
      'status': answered ? 'answered' : 'active',
      'correct': answered ? true : null,
      'selected': answered ? true : null,
      'server_now': DateTime.utc(2026).toIso8601String(),
      'retry_at': answered
          ? DateTime.utc(
              2026,
            ).add(const Duration(minutes: 10)).toIso8601String()
          : null,
      'location': location(owner: answered ? 'Blue' : null, revision: revision),
    });

class QuizTransport implements QuizRepository {
  List<QuizLocation> rows = [QuizLocation.fromJson(location())];
  bool loseResponse = false;
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
    return attempt(answered: true, revision: 1);
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
        find.text('Correct! One point saved for your team.'),
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
    'actual diamond/horse/plant/cat Lotties switch by proximity, keep team colors and survive taps',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final locations = [
        QuizLocation.fromJson(location(owner: 'Blue')),
        QuizLocation.fromJson(
          location(id: 'plant', animation: 'plant', owner: 'Red'),
        ),
        QuizLocation.fromJson(
          location(id: 'cats', animation: 'cats', owner: 'Blue'),
        ),
      ];
      final positions = {
        'horse': const Offset(100, 220),
        'horse#0': const Offset(100, 220),
        'plant': const Offset(290, 220),
        'plant#0': const Offset(290, 220),
        'cats': const Offset(195, 430),
        'cats#0': const Offset(195, 430),
      };
      final key = GlobalKey();
      var opened = 0;
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
                    revealed: revealed,
                    onOpen: (_) => opened++,
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
      await capture(tester, key, 'diamonds-390x844');
      await tester.tap(find.byKey(const ValueKey('horse:diamond')));
      expect(opened, 1);
      expect(
        find.byKey(const ValueKey('horse:diamond')),
        findsOneWidget,
        reason: 'tap never reveals animation',
      );
      await render({'horse', 'plant', 'cats'});
      expect(find.byKey(const ValueKey('horse:0')), findsOneWidget);
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
      await render({});
      expect(find.byKey(const ValueKey('horse:diamond')), findsOneWidget);
      expect(find.byKey(const ValueKey('horse:0')), findsNothing);
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
