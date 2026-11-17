import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:campus_app/map/campus_fix.dart';
import 'package:campus_app/map/campus_geography.dart';
import 'package:campus_app/nearby/verified_friend_book.dart';
import 'package:campus_app/nearby/offline_nearby_repository.dart';
import 'package:campus_app/nearby/offline_friend_repository.dart';
import 'package:campus_app/nearby/friend_controller.dart';
import 'package:campus_app/nearby/friend_protocol.dart';
import 'package:campus_app/nearby/nearby_controller.dart';
import 'package:campus_app/nearby/nearby_models.dart';
import 'offline_bluetooth_test.dart' as fixture;
import 'nearby_players_test.dart' as discovery;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'GPS goes through proved friend channels offline, and close/removal withdraws positions',
    () async {
      SharedPreferences.setMockInitialValues({});
      final internet = fixture.NoInternet();
      final previous = HttpOverrides.current;
      HttpOverrides.global = internet;
      final ba = VerifiedFriendBook('gps-a'), bb = VerifiedFriendBook('gps-b');
      final na = OfflineNearbyRepository(ba), nb = OfflineNearbyRepository(bb);
      final wa = FriendWire(), wb = FriendWire();
      final a = FriendController(
        OfflineFriendRepository(na),
        wa,
        localPosition: na.encodePosition,
        onPosition: na.receivePosition,
      );
      final b = FriendController(
        OfflineFriendRepository(nb),
        wb,
        localPosition: nb.encodePosition,
        onPosition: nb.receivePosition,
      );
      try {
        await ba.replace(fixture.snapshot(true));
        await bb.replace(fixture.snapshot(false));
        await na.open(fixture.sessionA);
        await nb.open(fixture.sessionB);
        na.identify(fixture.sessionB, fixture.codeB);
        nb.identify(fixture.sessionA, fixture.codeA);
        await na.challenge(fixture.sessionA, fixture.sessionB);
        await nb.confirm(fixture.sessionB, fixture.sessionA);
        na.ownFix = CampusFix(const CampusPoint(0, 0), 3, DateTime.now());
        nb.ownFix = CampusFix(const CampusPoint(.00001, 0), 3, DateTime.now());
        a.begin(fixture.sessionA);
        b.begin(fixture.sessionB);
        await a.refresh();
        await b.refresh();
        expect(
          (await na.read(fixture.sessionA)).peers.single.position,
          null,
          reason: 'discovery alone never shares GPS',
        );
        await a.open(fixture.sessionB);
        final id = a.conversations.single.grant.id;
        await wb.offer(id, 'central-a', peerToken: fixture.sessionA);
        await fixture.pump(wa, wb, id);
        expect(a.conversations.single.ready, true);
        expect(b.conversations.single.ready, true);
        await a.refresh();
        await b.refresh();
        await fixture.pump(wa, wb, id);
        expect(
          (await na.read(fixture.sessionA)).peers.single.position!.longitude,
          .00001,
        );
        expect(
          (await nb.read(fixture.sessionB)).peers.single.position!.longitude,
          0,
        );
        await a.close(id);
        expect(
          (await na.read(fixture.sessionA)).peers.single.position,
          null,
          reason: 'closing withdraws the marker immediately',
        );
        await fixture.pump(wa, wb, id);
        expect((await nb.read(fixture.sessionB)).peers.single.position, null);
        await ba.withdraw('relationship');
        na.position(
          fixture.sessionB,
          NearbyPosition(0, 0, DateTime.now().add(const Duration(seconds: 6))),
        );
        expect(
          (await na.read(fixture.sessionA)).peers.single.position,
          null,
          reason: 'removed friendship cannot retain a position',
        );
        expect(internet.attempts, 0);
      } finally {
        a.dispose();
        b.dispose();
        ba.dispose();
        bb.dispose();
        HttpOverrides.global = previous;
      }
    },
  );
  test('a lost position ACK cannot hold back a newer GPS fix', () async {
    SharedPreferences.setMockInitialValues({});
    final ba = VerifiedFriendBook('gps-a'), bb = VerifiedFriendBook('gps-b');
    await ba.replace(fixture.snapshot(true));
    await bb.replace(fixture.snapshot(false));
    final na = OfflineNearbyRepository(ba), nb = OfflineNearbyRepository(bb);
    await na.open(fixture.sessionA);
    await nb.open(fixture.sessionB);
    na.identify(fixture.sessionB, fixture.codeB);
    nb.identify(fixture.sessionA, fixture.codeA);
    await na.challenge(fixture.sessionA, fixture.sessionB);
    await nb.confirm(fixture.sessionB, fixture.sessionA);
    final wa = FriendWire(), wb = FriendWire();
    final a = FriendController(
      OfflineFriendRepository(na),
      wa,
      localPosition: na.encodePosition,
    )..begin(fixture.sessionA);
    final b = FriendController(
      OfflineFriendRepository(nb),
      wb,
      onPosition: nb.receivePosition,
    )..begin(fixture.sessionB);
    Future<void> deliverWithoutReturningACKs() async {
      for (var i = 0; i < 80; i++) {
        final frame = wa.next(a.conversations.single.grant.id);
        if (frame.isEmpty) break;
        await wb.receiveFrom('central-a', frame);
      }
    }

    try {
      await a.open(fixture.sessionB);
      final id = a.conversations.single.grant.id;
      await wb.offer(id, 'central-a', peerToken: fixture.sessionA);
      await fixture.pump(wa, wb, id);
      expect(a.conversations.single.ready, true);
      na.ownFix = CampusFix(const CampusPoint(0, 0), 3, DateTime.now());
      await a.refresh();
      await deliverWithoutReturningACKs();
      expect(
        (await nb.read(fixture.sessionB)).peers.single.position!.longitude,
        0,
      );
      na.ownFix = CampusFix(const CampusPoint(.00002, 0), 3, DateTime.now());
      await a.refresh();
      await deliverWithoutReturningACKs();
      expect(
        (await nb.read(fixture.sessionB)).peers.single.position!.longitude,
        .00002,
      );
      na.ownFix = null;
      await a.refresh();
      await deliverWithoutReturningACKs();
      expect(
        (await nb.read(fixture.sessionB)).peers.single.position,
        null,
        reason: 'GPS loss must supersede an unacknowledged position too',
      );
    } finally {
      a.dispose();
      b.dispose();
      ba.dispose();
      bb.dispose();
    }
  });
  test(
    'nearby players without proved sessions never become map positions',
    () async {
      final repo = discovery.FakeRepository();
      repo.peers.add(
        NearbyPeer(
          'stranger',
          'Stranger',
          DateTime.now().add(const Duration(seconds: 18)),
          NearbyPosition(0, 0, DateTime.now().add(const Duration(seconds: 6))),
        ),
      );
      final controller = NearbyController(
        repo,
        discovery.FakeRadio(),
        observeLifecycle: false,
      );
      await controller.enable();
      expect(controller.peers.single.position, null);
      expect(controller.status, contains('0 on map'));
      controller.dispose();
    },
  );
}
