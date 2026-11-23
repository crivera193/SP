import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:campus_app/nearby/ble_nearby_radio.dart';
import 'package:campus_app/nearby/hat_tip.dart';
import 'package:campus_app/nearby/nearby_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearby/nearby.dart';

import 'nearby_players_test.dart' show settings;

class _Service extends NearbyService {
  _Service({this.startPending, this.connectPending})
    : super(localDisplayName: 'SP test');

  final Completer<void>? startPending;
  final Completer<bool>? connectPending;
  final advertising = Completer<void>();
  final connecting = Completer<void>();
  final scanningStopped = Completer<void>();
  final peers = StreamController<List<Peer>>.broadcast();
  final states = StreamController<PeerConnectionStateUpdate>.broadcast();
  final payloads = StreamController<NearbyPayload>.broadcast();
  bool discovered = false, disposed = false;

  @override
  Stream<List<Peer>> get discoveredPeersStream => peers.stream;

  @override
  Stream<PeerConnectionStateUpdate> get peerStateStream => states.stream;

  @override
  Stream<NearbyPayload> get payloadReceivedStream => payloads.stream;

  void receive(String peerId, Map<String, Object> message) {
    payloads.add(
      NearbyPayload.fromBytes(
        peerId: peerId,
        bytes: Uint8List.fromList(utf8.encode(jsonEncode(message))),
      ),
    );
  }

  @override
  Future<void> startAdvertising({required AdvertisingOptions options}) async {
    expect(options.strategy, DiscoveryStrategy.bleOnly);
    advertising.complete();
    await startPending?.future;
  }

  @override
  Future<void> startDiscovery({required DiscoveryOptions options}) async {
    expect(options.strategy, DiscoveryStrategy.bleOnly);
    discovered = true;
  }

  @override
  Future<void> stopAdvertising() async {}

  @override
  Future<void> stopDiscovery() async => scanningStopped.complete();

  @override
  Future<bool> requestConnection(
    Peer peer, {
    Map<String, String> metadata = const {},
    String? preSharedKey,
    Duration timeout = const Duration(seconds: 30),
  }) {
    connecting.complete();
    return connectPending!.future;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await Future.wait([peers.close(), states.close(), payloads.close()]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final config = NearbyConfig(settings());
  BleNearbyRadio create(List<_Service> available) {
    final services = available.iterator;
    return BleNearbyRadio(
      identity: () => null,
      onIdentity: (_, _) {},
      teams: HatTipTeams('test')..colors = {'science': 'Yellow'},
      onChanged: () {},
      createService: () {
        expect(services.moveNext(), isTrue);
        return services.current;
      },
    );
  }

  Future<void> start(BleNearbyRadio radio) =>
      radio.start('session', config, (_) async => null, (_) async {}, fail);

  test(
    'return from Settings waits for a pending advertisement to stop',
    () async {
      final first = _Service(startPending: Completer<void>()),
          next = _Service();
      final radio = create([first, next]);
      final opening = start(radio);
      await first.advertising.future;
      final stopping = radio.stop();
      final restarting = start(radio);
      await Future<void>.delayed(Duration.zero);
      expect(first.disposed, isFalse);
      expect(next.advertising.isCompleted, isFalse);
      first.startPending!.complete();
      await opening;
      await stopping;
      await restarting;
      expect(first.discovered, isFalse);
      expect(first.disposed, isTrue);
      expect(next.discovered, isTrue);
      await radio.stop();
    },
  );

  test(
    'return from Settings waits for a late connection before disposal',
    () async {
      final first = _Service(connectPending: Completer<bool>()),
          next = _Service();
      final radio = create([first, next]);
      await start(radio);
      first.peers.add([
        Peer(
          id: 'peer',
          displayName: 'SP peer',
          discoveredVia: DiscoveryMedium.ble,
          bleDeviceId: 'device',
          lastSeen: DateTime.now(),
        ),
      ]);
      await first.connecting.future.timeout(const Duration(seconds: 5));
      final stopping = radio.stop();
      final restarting = start(radio);
      await first.scanningStopped.future.timeout(const Duration(seconds: 2));
      expect(first.disposed, isFalse);
      expect(next.advertising.isCompleted, isFalse);
      first.connectPending!.complete(true);
      await stopping;
      await restarting;
      expect(first.disposed, isTrue);
      expect(next.discovered, isTrue);
      await radio.stop();
    },
  );

  test('accepting phone uses fresh range from the BLE initiator', () async {
    final service = _Service();
    final radio = create([service]);
    addTearDown(radio.stop);
    await start(radio);
    service.states.add(
      PeerConnectionStateUpdate(
        peer: Peer(
          id: 'initiator',
          displayName: 'SP peer',
          discoveredVia: DiscoveryMedium.ble,
          bleDeviceId: 'device',
          lastSeen: DateTime.now(),
        ),
        state: PeerConnectionState.connected,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    const session = 'd3c203e0-5aa5-446a-8f89-d2861da4ac62';
    service.receive('initiator', {
      'type': 'hello',
      'session': session,
      'identity': '76801960-2da2-42e2-9f28-2cfb14fdaab3',
      'team': 'science',
    });
    await Future<void>.delayed(Duration.zero);
    expect(radio.hasHatTipTeam(session), isTrue);
    expect(radio.targets, isEmpty);

    service.receive('initiator', {'type': 'hat_range', 'close': true});
    await Future<void>.delayed(Duration.zero);
    expect(radio.targets.single.session, session);

    service.receive('initiator', {'type': 'hat_range', 'close': false});
    await Future<void>.delayed(Duration.zero);
    expect(radio.targets, isEmpty);

    service.receive('initiator', {'type': 'hat_range', 'close': true});
    await Future<void>.delayed(const Duration(milliseconds: 3100));
    expect(radio.targets, isEmpty);
  });
}
