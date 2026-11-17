import 'dart:io';
import 'package:campus_app/nearby/verified_friend_book.dart';
import 'package:campus_app/nearby/offline_nearby_repository.dart';
import 'package:campus_app/nearby/offline_friend_repository.dart';
import 'package:campus_app/nearby/friend_protocol.dart';
import 'package:campus_app/nearby/friend_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'nearby_players_test.dart' as fixtures;

class NoInternet extends HttpOverrides {
  int attempts = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError('Bluetooth must not use HTTP');
  }
}

const codeA = '10000000-0000-4000-8000-000000000001';
const codeB = '10000000-0000-4000-8000-000000000002';
const sessionA = '20000000-0000-4000-8000-000000000001';
const sessionB = '20000000-0000-4000-8000-000000000002';
Map<String, dynamic> snapshot(bool a, {bool accepted = true, String? key}) => {
  'self_code': a ? codeA : codeB,
  'settings': fixtures.settings(),
  'valid_until': DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
  'entries': [
    {
      'id': 'relationship',
      'code': a ? codeB : codeA,
      'label': a ? 'Friend B' : 'Friend A',
      'status': accepted ? 'accepted' : 'outgoing',
      'key_hex': accepted ? (key ?? 'ab' * 32) : null,
    },
  ],
};
Future<void> pump(FriendWire a, FriendWire b, String id) async {
  for (var i = 0; i < 160; i++) {
    final out = a.next(id);
    if (out.isNotEmpty) await b.receiveFrom('central-a', out);
    final incoming = b.read('central-a');
    if (incoming.isNotEmpty) await a.receive(id, incoming);
    if (out.isEmpty && incoming.isEmpty) break;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NoInternet internet;
  late VerifiedFriendBook bookA, bookB;
  late OfflineNearbyRepository nearA, nearB;
  late FriendWire wireA, wireB;
  late FriendController a, b;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    internet = NoInternet();
    HttpOverrides.global = internet;
    bookA = VerifiedFriendBook('a');
    bookB = VerifiedFriendBook('b');
    await bookA.replace(snapshot(true));
    await bookB.replace(snapshot(false));
    nearA = OfflineNearbyRepository(bookA);
    nearB = OfflineNearbyRepository(bookB);
    await nearA.open(sessionA);
    await nearB.open(sessionB);
    nearA.identify(sessionB, codeB);
    nearB.identify(sessionA, codeA);
    await nearA.challenge(sessionA, sessionB);
    await nearB.confirm(sessionB, sessionA);
    wireA = FriendWire();
    wireB = FriendWire();
    a = FriendController(OfflineFriendRepository(nearA), wireA)
      ..begin(sessionA);
    b = FriendController(OfflineFriendRepository(nearB), wireB)
      ..begin(sessionB);
  });
  tearDown(() {
    expect(
      internet.attempts,
      0,
      reason: 'No HTTP call may be attempted by Bluetooth',
    );
    a.dispose();
    b.dispose();
    bookA.dispose();
    bookB.dispose();
    HttpOverrides.global = null;
  });
  test(
    'fresh detection, mutual key proof and close/reopen need zero internet',
    () async {
      expect(
        (await nearA.read(sessionA)).peers.single.friendship,
        Friendship.accepted,
      );
      await a.open(sessionB);
      final id = a.conversations.single.grant.id;
      expect(await wireB.offer(id, 'central-a', peerToken: sessionA), isTrue);
      await pump(wireA, wireB, id);
      expect(a.conversations.single.ready, isTrue);
      expect(b.conversations.single.ready, isTrue);
      await a.close(id);
      expect(a.conversations, isEmpty);
      await pump(wireA, wireB, id);
      expect(
        b.conversations,
        isEmpty,
        reason: 'Authenticated close reaches the peer without HTTP',
      );
      await a.open(sessionB);
      expect(a.conversations.single.grant.id, isNot(id));
    },
  );
  test(
    'nonfriends remain visible but cannot open or accept a protected session',
    () async {
      await bookA.replace(snapshot(true, accepted: false));
      expect(
        (await nearA.read(sessionA)).peers.single.friendship,
        Friendship.none,
      );
      await a.open(sessionB);
      expect(a.conversations, isEmpty);
      await bookB.replace(snapshot(false, accepted: false));
      expect(
        await wireB.offer(codeA, 'central-a', peerToken: sessionA),
        isFalse,
      );
    },
  );
  test(
    'spoofing a known identity without its shared credential cannot prove friendship',
    () async {
      await bookB.replace(snapshot(false, key: 'cd' * 32));
      await a.open(sessionB);
      final id = a.conversations.single.grant.id;
      expect(await wireB.offer(id, 'central-a', peerToken: sessionA), isTrue);
      await pump(wireA, wireB, id);
      expect(a.conversations.single.ready, isFalse);
      expect(b.conversations.single.ready, isFalse);
    },
  );
  test(
    'cached permissions survive app reload and remain scoped to their account',
    () async {
      final reload = VerifiedFriendBook('a');
      await reload.load();
      expect(reload.byCode(codeB), isNotNull);
      final other = VerifiedFriendBook('another-account');
      await other.load();
      expect(other.byCode(codeB), isNull);
      reload.dispose();
      other.dispose();
    },
  );
  test(
    'expired credentials, local withdrawal and stale BLE revoke access without HTTP',
    () async {
      await a.open(sessionB);
      final id = a.conversations.single.grant.id;
      await wireB.offer(id, 'central-a', peerToken: sessionA);
      await pump(wireA, wireB, id);
      await bookA.withdraw('relationship');
      await a.refresh();
      expect(a.conversations, isEmpty);
      await bookA.replace({
        ...snapshot(true),
        'valid_until': DateTime.now()
            .subtract(const Duration(seconds: 1))
            .toIso8601String(),
      });
      await a.open(sessionB);
      expect(a.conversations, isEmpty);
      await bookA.replace(snapshot(true));
      await nearA.close(sessionA);
      await a.open(sessionB);
      expect(a.conversations, isEmpty);
    },
  );
  test(
    'verified friends survive login-token expiry and persisted removal',
    () async {
      await bookA.replace({
        ...snapshot(true),
        'trust_policy': 'until_friend_change',
        'valid_until': null,
      });
      final reload = VerifiedFriendBook('a');
      await reload.load();
      expect(reload.valid, isTrue);
      expect(reload.byCode(codeB), isNotNull);
      await a.open(sessionB);
      expect(a.conversations, hasLength(1));
      await reload.withdraw('relationship');
      final removed = VerifiedFriendBook('a');
      await removed.load();
      expect(removed.byCode(codeB), isNull);
      reload.dispose();
      removed.dispose();
    },
  );
}
