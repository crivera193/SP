import 'dart:io';

import 'package:campus_app/nearby/contact_log.dart';
import 'package:campus_app/nearby/friend_protocol.dart';
import 'package:campus_app/nearby/nearby_models.dart';
import 'package:campus_app/nearby/nearby_controller.dart';
import 'package:campus_app/nearby/offline_nearby_repository.dart';
import 'package:campus_app/nearby/offline_friend_repository.dart';
import 'package:campus_app/nearby/verified_friend_book.dart';
import 'package:campus_app/nearby/nearby_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'nearby_players_test.dart' as discovery;
import 'offline_bluetooth_test.dart' as fixtures;

const selfSession = '11111111-0000-4000-8000-000000000001';
const peerSession = '22222222-0000-4000-8000-000000000002';
const channel = '33333333-0000-4000-8000-000000000003';
const encounter = Duration(seconds: 18);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('saved progression and sync status stay out of Nearby', (
    tester,
  ) async {
    final log = ContactLog('fixture');
    addTearDown(log.dispose);
    await log.load();
    final controller = NearbyController(
      discovery.FakeRepository(),
      discovery.FakeRadio(),
      contacts: log,
      observeLifecycle: false,
    );
    addTearDown(controller.dispose);
    await log.acknowledge(
      {},
      ContactProgress.fromJson({
        'level': 10,
        'quiz_points': 2,
        'friend_seconds': 5400,
        'seconds_per_level': 600,
        'seconds_into_level': 0,
      }),
    );
    log.syncFailed();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: NearbyPanel(controller: controller)),
      ),
    );
    expect(find.text('Nearby players'), findsOneWidget);
    expect(find.text('Level 10'), findsNothing);
    expect(find.textContaining('Correct quiz'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text(log.error!), findsNothing);
    expect(log.progress?.level, 10);
    expect(log.progress?.quizPoints, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  test(
    'only fresh verified receipts count; cached detections, gaps and pause do not',
    () async {
      var now = DateTime.utc(2026, 11, 18), elapsed = Duration.zero;
      final log = ContactLog('a', now: () => now, elapsed: () => elapsed);
      await log.load();
      void advance(int seconds) {
        now = now.add(Duration(seconds: seconds));
        elapsed += Duration(seconds: seconds);
      }

      NearbyPeer peer({Friendship status = Friendship.accepted}) => NearbyPeer(
        peerSession,
        'Player 10000000',
        now.add(encounter),
        null,
        friendship: status,
        identityCode: fixtures.codeB,
      );
      void sample({
        bool verified = true,
        Friendship status = Friendship.accepted,
      }) => log.sample(
        selfSession,
        [peer(status: status)],
        encounter,
        verified ? {peerSession: channel} : {},
      );
      sample(verified: false);
      advance(4);
      sample(verified: false);
      expect(log.pending.every((r) => r.durationMs == 0), isTrue);
      sample(); // Confirmation starts a new baseline; no retrospective credit.
      advance(4);
      sample();
      expect(log.pending.last.durationMs, 4000);
      final cached = peer(), count = log.pending.length;
      advance(4);
      log.sample(selfSession, [cached], encounter, {peerSession: channel});
      expect(
        log.pending.length,
        count,
        reason: 'cached results cannot manufacture elapsed time',
      );
      advance(30);
      sample();
      expect(log.pending.last.durationMs, 0);
      advance(4);
      sample();
      expect(log.pending.last.durationMs, 4000);
      log.pause();
      advance(60);
      sample();
      expect(log.pending.last.durationMs, 0);
      advance(4);
      sample(status: Friendship.none);
      expect(log.pending.last.durationMs, 0);
      expect(log.pending.last.contactId, isNull);
      await log.save();
      log.dispose();
    },
  );
  test(
    'clock jumps, changed sessions and changed channels never grant a missing interval',
    () async {
      var now = DateTime.utc(2026, 11, 18), elapsed = Duration.zero;
      final log = ContactLog('a', now: () => now, elapsed: () => elapsed);
      await log.load();
      void sample(String session, String id) => log.sample(
        session,
        [
          NearbyPeer(
            peerSession,
            'fixture',
            now.add(encounter),
            null,
            friendship: Friendship.accepted,
            identityCode: fixtures.codeB,
          ),
        ],
        encounter,
        {peerSession: id},
      );
      sample(selfSession, channel);
      now = now.add(const Duration(hours: 1));
      elapsed += const Duration(seconds: 4);
      sample(selfSession, channel);
      expect(log.pending.last.durationMs, 0);
      now = now.subtract(const Duration(minutes: 30));
      elapsed += const Duration(seconds: 4);
      sample(selfSession, channel);
      expect(log.pending.last.durationMs, 0);
      now = now.add(const Duration(seconds: 4));
      elapsed += const Duration(seconds: 4);
      sample(peerSession, channel);
      expect(log.pending.last.durationMs, 0);
      now = now.add(const Duration(seconds: 4));
      elapsed += const Duration(seconds: 4);
      sample(selfSession, selfSession);
      expect(log.pending.last.durationMs, 0);
      await log.save();
      log.dispose();
    },
  );
  test(
    'pending IDs survive restart and failed sync; acknowledging a batch preserves newer records and account isolation',
    () async {
      var now = DateTime.utc(2026, 11, 18), elapsed = Duration.zero;
      final original = ContactLog('a', now: () => now, elapsed: () => elapsed);
      await original.load();
      original.sample(
        selfSession,
        [NearbyPeer(peerSession, 'fixture', now.add(encounter), null)],
        encounter,
        {},
      );
      await original.save();
      final id = original.pending.single.id;
      original.dispose();
      final loaded = ContactLog('a', now: () => now, elapsed: () => elapsed);
      await loaded.load();
      expect(loaded.pending.single.id, id);
      loaded.syncFailed();
      expect(loaded.pending.single.id, id);
      now = now.add(const Duration(seconds: 4));
      elapsed += const Duration(seconds: 4);
      loaded.sample(
        selfSession,
        [NearbyPeer(peerSession, 'fixture', now.add(encounter), null)],
        encounter,
        {},
      );
      await loaded.acknowledge(
        {id},
        ContactProgress.fromJson({
          'level': 2,
          'quiz_points': 1,
          'friend_seconds': 600,
          'seconds_per_level': 600,
          'seconds_into_level': 0,
        }),
      );
      expect(loaded.pending, hasLength(1));
      expect(loaded.progress!.level, 2);
      final other = ContactLog('b');
      await other.load();
      expect(other.pending, isEmpty);
      expect(other.progress, isNull);
      final after = ContactLog('a');
      await after.load();
      expect(after.pending.single.id, loaded.pending.single.id);
      expect(after.progress!.friendSeconds, 600);
      loaded.dispose();
      other.dispose();
      after.dispose();
    },
  );
  test(
    'discovery contact logging uses actual offline repositories without opening GPS sessions or HTTP',
    () async {
      final internet = fixtures.NoInternet();
      HttpOverrides.global = internet;
      final ba = VerifiedFriendBook('a'), bb = VerifiedFriendBook('b');
      final la = ContactLog('a'), lb = ContactLog('b');
      await ba.replace(fixtures.snapshot(true));
      await bb.replace(fixtures.snapshot(false));
      await la.load();
      await lb.load();
      final na = OfflineNearbyRepository(ba), nb = OfflineNearbyRepository(bb);
      final wa = FriendWire(), wb = FriendWire();
      final a = NearbyController(
        na,
        discovery.FakeRadio(),
        contacts: la,
        observeLifecycle: false,
        friendRepository: OfflineFriendRepository(na),
        friendWire: wa,
      );
      final b = NearbyController(
        nb,
        discovery.FakeRadio(),
        contacts: lb,
        observeLifecycle: false,
        friendRepository: OfflineFriendRepository(nb),
        friendWire: wb,
      );
      try {
        await a.enable();
        await b.enable();
        final sa = na.active!, sb = nb.active!;
        na.identify(sb, fixtures.codeB);
        nb.identify(sa, fixtures.codeA);
        await na.confirm(sa, sb);
        await nb.confirm(sb, sa);
        await a.refresh();
        await b.refresh();
        final id = sa.compareTo(sb) < 0 ? sa : sb;
        expect(la.pending.any((r) => r.contactId == id), isTrue);
        expect(lb.pending.any((r) => r.contactId == id), isTrue);
        expect(a.friends!.conversations, isEmpty);
        expect(b.friends!.conversations, isEmpty);
        expect(a.hasVerifiedSession(sb), isFalse);
        expect(b.hasVerifiedSession(sa), isFalse);
        expect(internet.attempts, 0);
        await a.disable();
        await b.disable();
        await la.save();
        await lb.save();
      } finally {
        a.dispose();
        b.dispose();
        la.dispose();
        lb.dispose();
        ba.dispose();
        bb.dispose();
        HttpOverrides.global = null;
      }
    },
  );
}
