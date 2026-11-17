import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:campus_app/nearby/friend_controller.dart';
import 'package:campus_app/nearby/friend_protocol.dart';
import 'package:campus_app/nearby/nearby_controller.dart';
import 'package:campus_app/nearby/nearby_models.dart';
import 'package:campus_app/nearby/nearby_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'nearby_players_test.dart' as discovery;

const channelId = '20000000-0000-4000-8000-000000000001';

class FriendServer {
  bool accepted = true, online = true, closed = false;
  Completer<void>? opening;
  FriendGrant grant(String actor) => FriendGrant(
    id: channelId,
    peerToken: actor == 'a' ? 'b' : 'a',
    peerId: actor == 'a' ? 'peer-b' : 'peer-a',
    label: actor == 'a' ? 'Player B' : 'Player A',
    keyHex: 'ab' * 32,
    relationshipId: 'relationship',
    first: actor == 'a',
    expiresAt: DateTime.now().add(const Duration(seconds: 20)),
  );
}

class FriendRepo implements FriendRepository {
  FriendRepo(this.server, this.actor);
  final FriendServer server;
  final String actor;
  void verify(String session) {
    if (!server.online || session != actor) throw StateError('unavailable');
  }

  @override
  Future<List<FriendEntry>> readFriends(String session) async {
    verify(session);
    return [
      FriendEntry(
        'relationship',
        actor == 'a' ? 'Player B' : 'Player A',
        server.accepted ? Friendship.accepted : Friendship.outgoing,
      ),
    ];
  }

  @override
  Future<void> requestFriend(String session, String peerId) async {
    verify(session);
  }

  @override
  Future<void> respondFriend(
    String session,
    String relationship,
    String action,
  ) async {
    verify(session);
    server.accepted = action == 'accept';
  }

  @override
  Future<FriendGrant> openChannel(String session, String peerId) async {
    verify(session);
    await server.opening?.future;
    if (!server.accepted || peerId != server.grant(actor).peerId) {
      throw StateError('not a friend');
    }
    server.closed = false;
    return server.grant(actor);
  }

  @override
  Future<FriendGrant?> checkChannel(String session, String channel) async {
    verify(session);
    return channel == channelId && server.accepted && !server.closed
        ? server.grant(actor)
        : null;
  }

  @override
  Future<void> closeChannel(String session, String channel) async {
    verify(session);
    server.closed = true;
  }
}

class UiNearbyRepository extends discovery.FakeRepository {
  @override
  Future<NearbySession> open(String request) async =>
      NearbySession('a', NearbyConfig(discovery.settings()));
}

Future<void> pumpWire(FriendWire a, FriendWire b, {int rounds = 160}) async {
  for (var i = 0; i < rounds; i++) {
    final out = a.next(channelId);
    expect(out.length, lessThanOrEqualTo(20));
    if (out.isNotEmpty) await b.receiveFrom('central-a', out);
    final incoming = b.read('central-a');
    expect(incoming.length, lessThanOrEqualTo(20));
    if (incoming.isNotEmpty) await a.receive(channelId, incoming);
    if (out.isEmpty && incoming.isEmpty) break;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FriendServer server;
  late FriendWire wireA, wireB;
  late FriendController a, b;
  late List<Map<String, dynamic>?> receivedA, receivedB;
  Map<String, dynamic>? positionA, positionB;
  setUp(() {
    server = FriendServer();
    wireA = FriendWire();
    wireB = FriendWire();
    receivedA = [];
    receivedB = [];
    positionA = null;
    positionB = null;
    a = FriendController(
      FriendRepo(server, 'a'),
      wireA,
      localPosition: () => positionA,
      onPosition: (_, fix) => receivedA.add(fix),
    )..begin('a');
    b = FriendController(
      FriendRepo(server, 'b'),
      wireB,
      localPosition: () => positionB,
      onPosition: (_, fix) => receivedB.add(fix),
    )..begin('b');
  });
  tearDown(() {
    a.dispose();
    b.dispose();
  });
  Future<void> connect() async {
    await a.open('peer-b');
    expect(await wireB.offer(channelId, 'central-a'), isTrue);
    expect(await wireA.offer(channelId, 'central-b'), isTrue);
    await pumpWire(wireA, wireB);
    expect(a.conversations.single.ready, isTrue);
    expect(b.conversations.single.ready, isTrue);
  }

  test(
    'pending/nonfriends cannot open or accept a communication session',
    () async {
      server.accepted = false;
      await a.open('peer-b');
      expect(a.conversations, isEmpty);
      expect(await wireB.offer(channelId, 'outsider'), isFalse);
      expect(wireB.read('outsider'), isEmpty);
      expect(b.conversations, isEmpty);
    },
  );
  test(
    'both peers prove key possession before protected position data',
    () async {
      await a.open('peer-b');
      expect(a.conversations.single.ready, isFalse);
      positionA = {'fixture': 'a'};
      positionB = {'fixture': 'b'};
      await a.refresh();
      expect(receivedB, isEmpty);
      expect(await wireB.offer(channelId, 'central-a'), isTrue);
      await pumpWire(wireA, wireB);
      await a.refresh();
      await b.refresh();
      await pumpWire(wireA, wireB);
      expect(receivedA, [positionB]);
      expect(receivedB, [positionA]);
      expect(a.conversations.single.pendingPosition, isNull);
      expect(b.conversations.single.pendingPosition, isNull);
    },
  );
  test(
    'lost frames and ACKs retry without duplicate application delivery',
    () async {
      await connect();
      positionA = {'fixture': 1};
      await a.refresh();
      // Lose initial data, then deliver it while losing the reverse ACK.
      wireA.next(channelId);
      for (var i = 0; i < 90; i++) {
        final frame = wireA.next(channelId);
        if (frame.isNotEmpty) await wireB.receiveFrom('central-a', frame);
        wireB.next(channelId);
      }
      await pumpWire(wireA, wireB);
      expect(receivedB, [positionA]);
      expect(a.conversations.single.pendingPosition, isNull);
    },
  );
  test(
    'forged ciphertext, reflected packets and wrong channel keys are rejected',
    () async {
      final sender = FriendCipher(server.grant('a'));
      final receiver = FriendCipher(server.grant('b'));
      final packet = await sender.encrypt({'type': 'hello'});
      expect((await receiver.decrypt(packet)).duplicate, isFalse);
      expect((await receiver.decrypt(packet)).duplicate, isTrue);
      final tampered = Uint8List.fromList(packet)..[5] ^= 1;
      await expectLater(receiver.decrypt(tampered), throwsA(anything));
      await expectLater(sender.decrypt(packet), throwsA(anything));
      final original = server.grant('b');
      final wrong = FriendCipher(
        FriendGrant(
          id: original.id,
          peerToken: original.peerToken,
          peerId: original.peerId,
          label: original.label,
          keyHex: 'cd' * 32,
          relationshipId: original.relationshipId,
          first: original.first,
          expiresAt: original.expiresAt,
        ),
      );
      await expectLater(wrong.decrypt(packet), throwsA(anything));
      final differentChannel = FriendCipher(
        FriendGrant(
          id: '20000000-0000-4000-8000-000000000002',
          peerToken: original.peerToken,
          peerId: original.peerId,
          label: original.label,
          keyHex: original.keyHex,
          relationshipId: original.relationshipId,
          first: original.first,
          expiresAt: original.expiresAt,
        ),
      );
      await expectLater(differentChannel.decrypt(packet), throwsA(anything));
    },
  );
  test(
    'friend removal and network loss deny receive and clear active sessions',
    () async {
      await connect();
      positionA = {'fixture': 1};
      await a.refresh();
      server.accepted = false;
      await pumpWire(wireA, wireB);
      expect(b.conversations, isEmpty);
      await a.refresh();
      expect(a.conversations, isEmpty);
      server.accepted = true;
      // New controllers represent a fresh discovery lifecycle, never a reset nonce
      // counter for a still-open channel.
      await a.suspend();
      await b.suspend();
      a.begin('a');
      b.begin('b');
      await connect();
      server.online = false;
      await b.refresh();
      expect(b.conversations, isEmpty);
      expect(b.error, isNotNull);
    },
  );
  test('late open cannot survive suspension/account switch', () async {
    server.opening = Completer<void>();
    final opening = a.open('peer-b');
    await Future<void>.delayed(Duration.zero);
    await a.suspend();
    a.begin('new-account');
    server.opening!.complete();
    await opening;
    expect(a.conversations, isEmpty);
    expect(wireA.channelFor('b'), isNull);
    expect(server.closed, isTrue);
  });
  test(
    'Bluetooth encounter expiry closes communication while retaining friendship',
    () async {
      await connect();
      a.expire(nearby: {});
      expect(a.conversations, isEmpty);
      expect(server.accepted, isTrue);
      expect(wireA.channelFor('b'), isNull);
    },
  );
  test(
    'protected packet bounds and malformed/unbound frames fail closed',
    () async {
      await connect();
      await expectLater(
        FriendCipher(server.grant('a')).encrypt({'fixture': 'x' * 600}),
        throwsStateError,
      );
      for (final bytes in [
        Uint8List(0),
        Uint8List(30),
        Uint8List.fromList([0, 0, 0, 0, 255, 255, 1]),
      ]) {
        await wireB.receiveFrom('unbound', bytes);
        await wireB.receive(channelId, bytes);
      }
      expect(receivedB, isEmpty);
    },
  );
  testWidgets(
    'nearby UI locks nonfriends and offers session controls without chat',
    (tester) async {
      final repository = UiNearbyRepository();
      final now = DateTime.now();
      repository.peers.addAll([
        NearbyPeer(
          'stranger',
          'Player nearby',
          now.add(const Duration(seconds: 18)),
          null,
        ),
        NearbyPeer(
          'peer-b',
          'Player B',
          now.add(const Duration(seconds: 18)),
          null,
          friendship: Friendship.accepted,
          relationshipId: 'relationship',
        ),
      ]);
      final controller = NearbyController(
        repository,
        discovery.FakeRadio(),
        observeLifecycle: false,
        friendRepository: FriendRepo(server, 'a'),
        friendWire: wireA,
      );
      addTearDown(controller.dispose);
      tester.view.physicalSize = const Size(1080, 2200);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final key = GlobalKey();
      await tester.runAsync(() async {
        await (FontLoader(
          'Inter',
        )..addFont(rootBundle.load('assets/fonts/Inter-Variable.ttf'))).load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            useMaterial3: true,
            fontFamily: 'Inter',
            colorSchemeSeed: const Color(0xff123d2b),
          ),
          home: Scaffold(
            body: RepaintBoundary(
              key: key,
              child: ColoredBox(
                color: const Color(0xfff8faf6),
                child: NearbyPanel(controller: controller),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(controller.enable);
      await tester.pumpAndSettle();
      expect(find.text('Detected · communication locked'), findsOneWidget);
      expect(find.byTooltip('Open Bluetooth session'), findsOneWidget);
      expect(find.text('Player nearby'), findsNothing);
      expect(find.text('Player B'), findsNothing);
      Future<void> capture(String name) async {
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 3);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('output/friends/$name.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await capture('detected-players');
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Open Bluetooth session'));
        for (var i = 0; i < 100 && controller.friends!.busy; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        await wireB.offer(channelId, 'central-a');
        await pumpWire(wireA, wireB);
      });
      await tester.pumpAndSettle();
      expect(find.text('Verified Bluetooth session'), findsOneWidget);
      expect(find.text('Player B'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Send'), findsNothing);
      expect(tester.takeException(), isNull);
      await capture('verified-nearby-panel');
      await tester.ensureVisible(find.byTooltip('Close Bluetooth session'));
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Close Bluetooth session'));
        for (
          var i = 0;
          i < 100 && controller.friends!.conversations.isNotEmpty;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      });
      await tester.pumpAndSettle();
      expect(controller.friends!.conversations, isEmpty);
      expect(find.byTooltip('Open Bluetooth session'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: NearbyPlayerMarker())),
      );
      expect(find.byType(Text), findsNothing);
      expect(find.byIcon(Icons.person_pin_circle), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
