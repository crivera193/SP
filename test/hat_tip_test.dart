import 'package:campus_app/nearby/ble_nearby_radio.dart';
import 'package:campus_app/nearby/hat_tip.dart';
import 'package:campus_app/nearby/nearby_controller.dart';
import 'package:campus_app/nearby/nearby_models.dart';
import 'package:campus_app/nearby/nearby_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'friend_communication_test.dart' show UiNearbyRepository;

class _HatRadio extends BleNearbyRadio {
  _HatRadio()
    : super(
        identity: () => null,
        onIdentity: (_, _) {},
        teams: HatTipTeams('a'),
        onChanged: () {},
      );

  @override
  List<HatTipTarget> get targets => const [
    HatTipTarget('first', 'Yellow'),
    HatTipTarget('second', 'Yellow'),
  ];

  final sent = <String>[];

  @override
  Future<void> prepare() async {}

  @override
  Future<void> start(
    String session,
    NearbyConfig config,
    Future<String?> Function(String) challenge,
    Future<void> Function(String) confirm,
    void Function(String) onFailure,
  ) async {}

  @override
  Future<void> tip(String session) async => sent.add(session);
}

void main() {
  test('hat-tip range ignores stale, duplicate and noisy sightings', () {
    final now = DateTime.utc(2026);
    final signal = HatTipSignal();
    signal.observe(now, -46);
    signal.observe(now, -46);
    signal.observe(now.add(const Duration(seconds: 1)), null);
    expect(signal.isClose(now), isFalse);

    signal.observe(now.add(const Duration(seconds: 1)), -80);
    signal.observe(now.add(const Duration(seconds: 2)), -60);
    expect(signal.isClose(now.add(const Duration(seconds: 2))), isTrue);
    expect(signal.isClose(now.add(const Duration(seconds: 7))), isFalse);
  });

  test('one strong reading cannot make a weak peer eligible', () {
    final now = DateTime.utc(2026);
    final signal = HatTipSignal()
      ..observe(now, -78)
      ..observe(now.add(const Duration(seconds: 1)), -50)
      ..observe(now.add(const Duration(seconds: 2)), -76);
    expect(signal.isClose(now.add(const Duration(seconds: 2))), isFalse);
  });

  testWidgets(
    'same-team hat tips target the chosen player without displaying codes',
    (tester) async {
      final radio = _HatRadio();
      final expires = DateTime.now().add(const Duration(seconds: 30));
      final repository = UiNearbyRepository()
        ..peers.addAll([
          NearbyPeer('first', 'Player', expires, null),
          NearbyPeer('second', 'Player', expires, null),
        ]);
      final controller = NearbyController(
        repository,
        radio,
        observeLifecycle: false,
      );
      addTearDown(controller.dispose);
      await controller.enable();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: NearbyPanel(controller: controller)),
        ),
      );
      final tips = find.widgetWithText(
        FilledButton,
        '🤠 Wave and tip your hat to the Yellow Vaquero',
      );
      final second = find.descendant(
        of: find.byKey(const ValueKey('detected-second')),
        matching: tips,
      );
      expect(tips, findsNWidgets(2));
      expect(second, findsOneWidget);
      expect(find.textContaining('Vaquero code'), findsNothing);
      expect(tester.getSize(second).height, greaterThanOrEqualTo(48));
      await tester.tap(second);
      expect(radio.sent, ['second']);
      await controller.disable();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
