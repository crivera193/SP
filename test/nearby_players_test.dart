import 'dart:async';
import 'package:campus_app/map/campus_fix.dart';
import 'package:campus_app/map/campus_geography.dart';
import 'package:campus_app/nearby/nearby_controller.dart';
import 'package:campus_app/nearby/nearby_models.dart';
import 'package:campus_app/nearby/nearby_repository.dart';
import 'package:campus_app/nearby/nearby_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> settings() => {
  'enabled': true,
  'heartbeat_s': 4,
  'lease_s': 24,
  'encounter_s': 18,
  'challenge_s': 8,
  'fix_s': 6,
  'max_accuracy_m': 40,
  'max_peers': 12,
  'scan_s': 20,
  'pause_s': 5,
};

class FakeRadio implements NearbyRadio {
  Future<String?> Function(String)? challenge;
  Future<void> Function(String)? receipt;
  void Function(String)? failure;
  Completer<void>? preparing;
  String? prepareError;
  int starts = 0, stops = 0;
  @override
  Future<void> prepare() async {
    if (prepareError != null) throw StateError(prepareError!);
    await preparing?.future;
  }

  @override
  Future<void> start(
    String token,
    NearbyConfig config,
    Future<String?> Function(String) c,
    Future<void> Function(String) r,
    void Function(String) f,
  ) async {
    starts++;
    challenge = c;
    receipt = r;
    failure = f;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> openSettings() async {}
}

class FakeRepository implements NearbyRepository {
  int opens = 0, reads = 0, confirms = 0, challenges = 0;
  final closed = <String>[];
  final fixes = <CampusFix?>[];
  final peers = <NearbyPeer>[];
  Completer<NearbySession>? opening;
  Completer<NearbySnapshot>? reading;
  bool failRead = false;
  @override
  Future<NearbySession> open(String request) async {
    opens++;
    return opening?.future ??
        Future.value(NearbySession('session-$opens', NearbyConfig(settings())));
  }

  @override
  Future<void> heartbeat(String token, CampusFix? fix) async {
    fixes.add(fix);
  }

  @override
  Future<String?> challenge(String token, String peer) async {
    challenges++;
    return 'nonce';
  }

  @override
  Future<bool> confirm(String token, String nonce) async {
    confirms++;
    return true;
  }

  @override
  Future<NearbySnapshot> read(String token) async {
    reads++;
    if (failRead) throw StateError('offline');
    return reading?.future ??
        Future.value(NearbySnapshot(List.of(peers), NearbyConfig(settings())));
  }

  @override
  Future<void> close(String token) async {
    closed.add(token);
  }
}

NearbyPeer peer(DateTime now) => NearbyPeer(
  'peer',
  'Player 1234',
  now.add(const Duration(seconds: 18)),
  NearbyPosition(26.30546, -98.17525, now.add(const Duration(seconds: 6))),
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeRepository repository;
  late FakeRadio radio;
  late NearbyController controller;
  setUp(() {
    repository = FakeRepository();
    radio = FakeRadio();
    controller = NearbyController(repository, radio, observeLifecycle: false);
  });
  tearDown(() => controller.dispose());

  test('GPS alone never initiates challenges or discovers a player', () async {
    await controller.enable();
    controller.updatePosition(
      CampusFix(const CampusPoint(-98.17525, 26.30546), 4, DateTime.now()),
    );
    await controller.refresh();
    expect(repository.fixes.last, isNotNull);
    expect(repository.challenges, 0);
    expect(repository.confirms, 0);
    expect(controller.peers, isEmpty);
    await radio.challenge!('bluetooth-token');
    expect(repository.challenges, 1);
  });
  test('permission denial does not allocate a server session', () async {
    radio.prepareError = 'Bluetooth denied';
    await controller.enable();
    expect(repository.opens, 0);
    expect(controller.running, isFalse);
    expect(controller.error, 'Bluetooth denied');
  });
  test('background during permission setup cannot start discovery', () async {
    radio.preparing = Completer<void>();
    final start = controller.enable();
    await Future<void>.delayed(Duration.zero);
    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    radio.preparing!.complete();
    await start;
    expect(repository.opens, 0);
    expect(radio.starts, 0);
  });
  test('late server startup is closed after leaving app', () async {
    repository.opening = Completer<NearbySession>();
    final start = controller.enable();
    await Future<void>.delayed(Duration.zero);
    controller.didChangeAppLifecycleState(AppLifecycleState.hidden);
    repository.opening!.complete(
      NearbySession('late', NearbyConfig(settings())),
    );
    await start;
    expect(repository.closed, contains('late'));
    expect(radio.starts, 0);
  });
  test(
    'background clears players immediately and invalidates late responses',
    () async {
      repository.peers.add(peer(DateTime.now()));
      await controller.enable();
      expect(controller.peers, hasLength(1));
      repository.reading = Completer<NearbySnapshot>();
      final refresh = controller.refresh();
      await Future<void>.delayed(Duration.zero);
      controller.didChangeAppLifecycleState(AppLifecycleState.inactive);
      expect(controller.peers, isEmpty);
      expect(controller.running, isFalse);
      repository.reading!.complete(
        NearbySnapshot([peer(DateTime.now())], NearbyConfig(settings())),
      );
      await refresh;
      expect(controller.peers, isEmpty);
    },
  );
  test(
    'a resumed session can poll while an old read is still pending',
    () async {
      await controller.enable();
      final oldRead = Completer<NearbySnapshot>();
      repository.reading = oldRead;
      final oldRefresh = controller.refresh();
      await Future<void>.delayed(Duration.zero);
      controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      repository.reading = null;
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(repository.opens, 2);
      expect(controller.running, isTrue);
      expect(repository.reads, 3);
      oldRead.complete(
        NearbySnapshot([peer(DateTime.now())], NearbyConfig(settings())),
      );
      await oldRefresh;
      expect(controller.peers, isEmpty);
    },
  );
  test(
    'GPS expiry removes position while Bluetooth detection remains',
    () async {
      final now = DateTime.now();
      repository.peers.add(peer(now));
      await controller.enable();
      controller.expire(now.add(const Duration(seconds: 7)));
      expect(controller.peers, hasLength(1));
      expect(controller.peers.single.position, isNull);
      controller.expire(now.add(const Duration(seconds: 19)));
      expect(controller.peers, isEmpty);
    },
  );
  test('turn off closes session and rejects old radio callbacks', () async {
    await controller.enable();
    final challenge = radio.challenge!, receipt = radio.receipt!;
    await controller.disable();
    await challenge('old-peer');
    await receipt('old-nonce');
    expect(repository.closed, contains('session-1'));
    expect(repository.challenges, 0);
    expect(repository.confirms, 0);
    expect(controller.enabled, isFalse);
  });
  test('network failure hides all positions and stops radio', () async {
    repository.peers.add(peer(DateTime.now()));
    await controller.enable();
    repository.failRead = true;
    await controller.refresh();
    expect(controller.peers, isEmpty);
    expect(controller.running, isFalse);
    expect(radio.stops, greaterThan(0));
    expect(repository.closed, contains('session-1'));
  });
  test('stale and invalid GPS are not republished as fresh fixes', () async {
    await controller.enable();
    controller.updatePosition(
      CampusFix(
        const CampusPoint(-98.17525, 26.30546),
        4,
        DateTime.now().subtract(const Duration(seconds: 7)),
      ),
    );
    await controller.refresh();
    expect(repository.fixes.last, isNull);
    controller.updatePosition(
      CampusFix(CampusPoint(double.nan, 26), 4, DateTime.now()),
    );
    await controller.refresh();
    expect(repository.fixes.last, isNull);
  });
  test('server deadlines account for transit and never renew stale GPS', () {
    final now = DateTime.utc(2026, 11, 5);
    final data = {
      'settings': settings(),
      'server_now': now.toIso8601String(),
      'players': [
        {
          'id': 'a',
          'label': 'Player a',
          'expires_at': now.add(const Duration(seconds: 18)).toIso8601String(),
          'position': {
            'latitude': 26.3,
            'longitude': -98.17,
            'accuracy_m': 3,
            'expires_at': now.add(const Duration(seconds: 1)).toIso8601String(),
          },
        },
      ],
    };
    final snapshot = SupabaseNearbyRepository.decode(
      data,
      now,
      const Duration(seconds: 2),
    );
    expect(snapshot.peers.single.position, isNull);
    expect(
      snapshot.peers.single.expiresAt,
      now.add(const Duration(seconds: 16)),
    );
    expect(
      () => NearbyConfig({...settings(), 'enabled': false}),
      throwsFormatException,
    );
    expect(
      () => NearbyConfig({...settings(), 'heartbeat_s': 100}),
      throwsFormatException,
    );
  });
  testWidgets('discovery panel explains sharing, enables and disables it', (
    tester,
  ) async {
    controller.dispose();
    controller = NearbyController(repository, radio, observeLifecycle: false);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: NearbyPanel(controller: controller)),
      ),
    );
    expect(find.textContaining('Bluetooth finds players'), findsOneWidget);
    await tester.tap(find.text('Turn on'));
    await tester.pumpAndSettle();
    expect(controller.running, isTrue);
    expect(find.text('Bluetooth on · no players detected'), findsOneWidget);
    await tester.tap(find.text('Turn off'));
    await tester.pump();
    expect(controller.enabled, isFalse);
    expect(controller.peers, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
