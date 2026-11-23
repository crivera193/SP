import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart' as gps;
import 'package:nearby/nearby.dart';
import 'package:universal_ble/universal_ble.dart';

import 'friend_protocol.dart';
import 'hat_tip.dart';
import 'nearby_models.dart';

const _serviceId = 'sp-nearby-v3';
const _sharedRangeFreshness = Duration(seconds: 3);
const _androidRssi = MethodChannel('com.example.campus_app/nearby_rssi');
final _uuid = RegExp(r'^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$');

/// Keeps the SP encounter and encrypted friend protocol on a single BLE radio.
class BleNearbyRadio implements NearbyRadio {
  BleNearbyRadio({
    required this.identity,
    required this.onIdentity,
    required this.teams,
    required this.onChanged,
    NearbyService Function()? createService,
  }) : _createService = createService ?? _newService;

  static NearbyService _newService() =>
      NearbyService(localDisplayName: 'SP Vaquero');

  final String? Function() identity;
  final void Function(String peerSession, String code) onIdentity;
  final HatTipTeams teams;
  final VoidCallback onChanged;
  final NearbyService Function() _createService;
  final friendWire = FriendWire();

  final _devices = <String, _Device>{};
  final _connections = <String, _Connection>{};
  final _initiated = <String>{};
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _tips = <String, String>{};
  final _seen = <(String, String)>{};
  List<(String, String)> _visibleTargets = const [];
  NearbyService? _service;
  int _generation = 0;
  Timer? _timer;
  Future<void> _stopWork = Future.value();
  Future<void>? _startupWork, _connectionWork;
  DateTime? _startedAt;
  NearbyConfig? _config;
  String? _session;
  Future<String?> Function(String)? _challenge;
  Future<void> Function(String)? _confirm;
  String? _connectingDevice;
  String? status, greeting, replyTo;

  List<HatTipTarget> get targets => [
    for (final link in _connections.values)
      if (_target(link) case final HatTipTarget target) target,
  ];
  bool hasHatTipTeam(String session) => _connections.values.any(
    (link) => link.session == session && teams.colors.containsKey(link.team),
  );

  HatTipTarget? _target(_Connection link) {
    final session = link.session;
    final color = teams.colors[link.team];
    final scan =
        _devices[link.device] ??
        _devices.values
            .where((device) => device.peer.id == link.id)
            .firstOrNull;
    final now = DateTime.now();
    final sharedRange = link.sharedRange;
    final close = switch (link.signal.median(now)) {
      final int strength => strength >= HatTipSignal.minimumDbm,
      _
          when sharedRange != null &&
              now.difference(sharedRange.receivedAt) < _sharedRangeFreshness =>
        sharedRange.close,
      _ => scan?.signal.isClose(now) ?? false,
    };
    if (session == null || color == null || !close) {
      return null;
    }
    return HatTipTarget(session, color);
  }

  @override
  Future<void> prepare() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      throw StateError('Nearby players need an Android phone or iPhone.');
    }
    if (Platform.isAndroid && !await UniversalBle.hasPermissions()) {
      await UniversalBle.requestPermissions();
      if (!await UniversalBle.hasPermissions()) {
        throw StateError('Allow Nearby devices in Settings, then retry.');
      }
    }
    final state = await UniversalBle.getBluetoothAvailabilityState();
    if (state == AvailabilityState.poweredOff) {
      throw StateError('Turn on Bluetooth, then retry Nearby players.');
    }
  }

  @override
  Future<void> start(
    String session,
    NearbyConfig config,
    Future<String?> Function(String peer) challenge,
    Future<void> Function(String nonce) confirm,
    void Function(String message) onFailure,
  ) async {
    final generation = _generation + 1;
    await stop();
    if (_generation != generation) return;
    final service = _createService();
    _service = service;
    _session = session;
    _config = config;
    _challenge = challenge;
    _confirm = confirm;
    _startedAt = DateTime.now();
    _subscriptions.addAll([
      service.discoveredPeersStream.listen((peers) {
        if (_service != service) return;
        for (final peer in peers.where(_isBle)) {
          _devices
              .putIfAbsent(peer.bleDeviceId!, () => _Device(peer))
              .update(peer);
        }
      }),
      service.peerStateStream.listen((event) {
        if (_service != service || !_isBle(event.peer)) return;
        switch (event.state) {
          case PeerConnectionState.connected:
            final device = event.peer.bleDeviceId!;
            final link = _Connection(
              event.peer.id,
              device,
              isCentral: _initiated.remove(device),
            );
            _connections[link.id] = link;
            debugPrint(
              'SP Nearby connected over BLE (${link.isCentral ? 'initiator' : 'acceptor'})',
            );
            unawaited(_exchange(service, link));
          case PeerConnectionState.disconnected:
            final link = _connections.remove(event.peer.id);
            if (link != null) unawaited(_closeSignalClient(link));
            onChanged();
          default:
            break;
        }
      }),
      service.payloadReceivedStream.listen((payload) {
        if (_service != service || payload.bytes == null) return;
        final link = _connections[payload.peerId];
        if (link == null ||
            payload.bytes!.length > 1024 ||
            link.incoming >= 8) {
          return;
        }
        link.incoming++;
        link.tail = link.tail
            .then((_) => _receive(service, link, payload.bytes!))
            .catchError((Object _) {})
            .whenComplete(() => link.incoming--);
      }),
      UniversalBle.availabilityStream.listen((state) {
        if (_service == service && state == AvailabilityState.poweredOff) {
          onFailure('Turn on Bluetooth, then retry Nearby players.');
        }
      }),
      UniversalBlePeripheral.advertisingStateStream.listen((event) {
        if (_service == service &&
            event.state == PeripheralAdvertisingState.error) {
          debugPrint('SP Nearby BLE advertising error: ${event.error}');
          onFailure('Nearby could not advertise over Bluetooth.');
        }
      }),
    ]);
    await (_startupWork = _startNative(service));
  }

  Future<void> _startNative(NearbyService service) async {
    await service.startAdvertising(
      options: const AdvertisingOptions(
        serviceId: _serviceId,
        strategy: DiscoveryStrategy.bleOnly,
      ),
    );
    if (_service != service) return;
    await service.startDiscovery(
      options: const DiscoveryOptions(
        serviceId: _serviceId,
        strategy: DiscoveryStrategy.bleOnly,
      ),
    );
    if (_service != service) return;
    if (service.advertisingPort != null) {
      throw StateError('Nearby opened a network listener.');
    }
    debugPrint('SP Nearby started BLE-only discovery and advertising');
    _timer = Timer.periodic(
      const Duration(milliseconds: 400),
      (_) => _tick(service),
    );
  }

  bool _isBle(Peer peer) =>
      peer.discoveredVia == DiscoveryMedium.ble &&
      peer.bleDeviceId != null &&
      peer.ipAddress == null &&
      peer.port == null;

  void _tick(NearbyService service) {
    if (_service != service) return;
    final now = DateTime.now();
    final config = _config!;
    _devices.removeWhere(
      (_, scan) => now.difference(scan.peer.lastSeen) > config.encounter,
    );
    for (final link in _connections.values.toList()) {
      if (now.difference(link.lastSeen) > config.encounter) {
        _connections.remove(link.id);
        unawaited(_closeSignalClient(link));
        unawaited(service.disconnectPeer(link.id).catchError((Object _) {}));
      } else {
        unawaited(_exchange(service, link));
        if ((link.isCentral ||
                (Platform.isAndroid && teams.colors.containsKey(link.team))) &&
            !link.readingSignal &&
            now.difference(link.lastSignalRead) >= const Duration(seconds: 1)) {
          unawaited(_readSignal(service, link, now));
        }
      }
    }
    // Give Android the first opportunity to connect across platforms.
    if (_connectingDevice == null &&
        _connections.length < config.maxPeers &&
        now.difference(_startedAt!) >
            Duration(seconds: Platform.isIOS ? 5 : 1)) {
      final candidate = _devices.values
          .where(
            (scan) =>
                now.difference(scan.attemptedAt) >= config.heartbeat &&
                !_connections.values.any(
                  (link) =>
                      link.device == scan.peer.bleDeviceId ||
                      link.id == scan.peer.id,
                ),
          )
          .firstOrNull;
      if (candidate != null) {
        candidate.attemptedAt = now;
        _connectingDevice = candidate.peer.bleDeviceId;
        _initiated.add(_connectingDevice!);
        _connectionWork = _connect(service, candidate.peer);
      }
    }
    final visible = targets
        .map((target) => (target.session, target.colorName))
        .toList();
    if (!listEquals(_visibleTargets, visible)) {
      _visibleTargets = visible;
      onChanged();
    }
  }

  Future<void> _connect(NearbyService service, Peer peer) async {
    var connected = false;
    try {
      connected = await service.requestConnection(
        peer,
        timeout: const Duration(seconds: 10),
      );
    } catch (error) {
      // A lost advertisement or simultaneous connection will be retried.
      debugPrint('SP Nearby BLE connection failed: ${error.runtimeType}');
    } finally {
      if (_service == service) {
        if (!connected) _initiated.remove(peer.bleDeviceId);
        _connectingDevice = null;
      }
    }
  }

  Future<void> _readSignal(
    NearbyService service,
    _Connection link,
    DateTime started,
  ) async {
    link.readingSignal = true;
    link.lastSignalRead = started;
    try {
      final strength = link.isCentral
          ? await UniversalBle.readRssi(
              link.device,
              timeout: const Duration(seconds: 2),
            )
          : await _androidRssi.invokeMethod<int>('read', link.device);
      if (strength == null && !link.reportedMissingSignal) {
        link.reportedMissingSignal = true;
        debugPrint('SP Nearby Android did not return an RSSI sample');
      }
      if (_service == service &&
          _connections[link.id] == link &&
          strength != null &&
          strength < 0 &&
          strength >= -127) {
        final now = DateTime.now();
        link.signal.observe(now, strength);
        final median = link.signal.median(now);
        if (median == null) return;
        final close = median >= HatTipSignal.minimumDbm;
        if (!link.isCentral && link.lastSignalClose != close) {
          link.lastSignalClose = close;
          debugPrint(
            'SP Nearby Android received-link BLE range: ${close ? 'close' : 'out of range'} ($median dBm)',
          );
        }
        // The BLE initiator can read RSSI for this link. The accepting phone
        // may no longer receive advertisements from it while connected.
        if (link.isCentral && link.session != null) {
          await _send(service, link, {'type': 'hat_range', 'close': close});
        }
      }
    } catch (error) {
      // A phone can still supply valid advertisement samples.
      if (!link.reportedMissingSignal) {
        link.reportedMissingSignal = true;
        debugPrint('SP Nearby BLE RSSI read failed: ${error.runtimeType}');
      }
    } finally {
      link.readingSignal = false;
    }
  }

  Future<void> _closeSignalClient(_Connection link) async {
    if (Platform.isAndroid && !link.isCentral) {
      await _androidRssi
          .invokeMethod<void>('close', link.device)
          .catchError((Object _) {});
    }
  }

  Future<void> _exchange(NearbyService service, _Connection link) async {
    if (_service != service || link.sending) return;
    final now = DateTime.now();
    final config = _config!;
    link.sending = true;
    try {
      if (now.difference(link.lastHello) >= config.heartbeat) {
        final code = identity();
        if (code != null) {
          link.lastHello = now;
          await _send(service, link, {
            'type': 'hello',
            'session': _session,
            'identity': code,
            'team': teams.ownTeamId,
          });
        }
      }
      if (_service != service) return;
      final session = link.session;
      final channel = session == null ? null : friendWire.channelFor(session);
      if (channel == null) return;
      final frames = [
        for (var i = 0; i < 8; i++)
          if (friendWire.next(channel) case final frame when frame.isNotEmpty)
            base64Encode(frame),
      ];
      if (frames.isNotEmpty) {
        await _send(service, link, {
          'type': 'friend',
          'channel': channel,
          'frames': frames,
        });
      }
    } finally {
      link.sending = false;
    }
  }

  Future<bool> _send(
    NearbyService service,
    _Connection link,
    Map<String, Object?> message,
  ) async {
    if (_service != service || _connections[link.id] != link) return false;
    try {
      await service.sendBytes(
        link.id,
        Uint8List.fromList(utf8.encode(jsonEncode(message))),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _receive(
    NearbyService service,
    _Connection link,
    Uint8List bytes,
  ) async {
    if (_service != service || _connections[link.id] != link) return;
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map<String, dynamic>) return;
    if (data case {
      'type': 'hello',
      'session': final String session,
      'identity': final String code,
    }) {
      if (!_uuid.hasMatch(session) ||
          !_uuid.hasMatch(code) ||
          session == _session ||
          code == identity() ||
          (link.session != null &&
              (link.session != session || link.identity != code))) {
        return;
      }
      link.session = session;
      link.identity = code;
      final team = data['team'];
      link.team = team is String && team.length <= 40 ? team : null;
      link.lastSeen = DateTime.now();
      onIdentity(session, code);
      await _challenge?.call(session);
      if (_service == service) await _confirm?.call(session);
      return;
    }
    final session = link.session;
    if (session == null ||
        DateTime.now().difference(link.lastSeen) > _config!.encounter) {
      return;
    }
    if (data case {'type': 'hat_range', 'close': final bool close}) {
      if (!link.isCentral) {
        if (link.sharedRange?.close != close) {
          debugPrint(
            'SP Nearby received a BLE range update: ${close ? 'close' : 'out of range'}',
          );
        }
        link.sharedRange = (receivedAt: DateTime.now(), close: close);
      }
      return;
    }
    if (data case {
      'type': 'friend',
      'channel': final String id,
      'frames': final List frames,
    }) {
      if (!_uuid.hasMatch(id) || frames.isEmpty || frames.length > 8) return;
      if (friendWire.channelFor(session) != id &&
          !await friendWire.offer(id, link.id, peerToken: session)) {
        return;
      }
      if (friendWire.channelFor(session) != id) return;
      for (final frame in frames) {
        if (_service != service) return;
        if (frame is String && frame.length <= 28) {
          await friendWire.receive(id, base64Decode(frame));
        }
      }
      return;
    }
    final id = data['id'];
    if (id is! String || !_uuid.hasMatch(id)) return;
    if (data['type'] == 'hat_receipt' && _tips[id] == link.id) {
      _tips.remove(id);
      status = 'Hat tip delivered';
      debugPrint('SP Nearby received a hat-tip receipt over BLE');
      onChanged();
    }
    if (data['type'] == 'hat_tip') {
      final key = (session, id);
      if (!_seen.contains(key)) {
        if (_seen.length >= 64) _seen.remove(_seen.first);
        _seen.add(key);
        greeting = '🤠 Howdy, partner! From a nearby player.';
        replyTo = session;
        debugPrint('SP Nearby handled a hat tip over BLE');
        onChanged();
      }
      await _send(service, link, {'type': 'hat_receipt', 'id': id});
    }
  }

  Future<void> tip(String session) async {
    final service = _service;
    final link = _connections.values
        .where((item) => item.session == session)
        .firstOrNull;
    if (service == null || link == null || _target(link) == null) {
      status = 'Couldn’t confirm delivery.';
      onChanged();
      return;
    }
    if (_tips.containsValue(link.id)) return;
    final id = NearbyProtocol.randomId();
    _tips[id] = link.id;
    status = 'Sending hat tip…';
    onChanged();
    if (await _send(service, link, {'type': 'hat_tip', 'id': id})) {
      await Future<void>.delayed(const Duration(seconds: 5));
    }
    if (_service == service && _tips.remove(id) != null) {
      status = 'Couldn’t confirm delivery.';
      onChanged();
    }
  }

  @override
  Future<void> stop() {
    _generation++;
    final service = _service;
    final startup = _startupWork;
    final connection = _connectionWork;
    _startupWork = _connectionWork = null;
    _service = null;
    _session = null;
    _timer?.cancel();
    final subscriptions = _subscriptions.toList();
    _subscriptions.clear();
    final closingLinks = _connections.values.toList();
    _connections.clear();
    _initiated.clear();
    _devices.clear();
    _tips.clear();
    _seen.clear();
    _visibleTargets = const [];
    _connectingDevice = null;
    greeting = replyTo = status = null;
    friendWire.clear();
    return _stopWork = _stopWork.catchError((Object _) {}).then((_) async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      if (service == null) return;
      await Future.wait(closingLinks.map(_closeSignalClient));
      // A native start can still be pending when SP leaves the foreground.
      await startup?.catchError((Object _) {});
      // Release the scan listener before a connecting transport can resume it.
      await Future.wait([
        service.stopDiscovery().catchError((Object _) {}),
        service.stopAdvertising().catchError((Object _) {}),
      ]);
      // requestConnection registers its session late. Let that finish before
      // closing the service so dispose also disconnects that session.
      await connection;
      await service.dispose();
    });
  }

  @override
  Future<void> openSettings() async {
    await gps.Geolocator.openAppSettings();
  }
}

class _Device {
  _Device(this.peer);
  Peer peer;
  final signal = HatTipSignal();
  DateTime attemptedAt = DateTime.fromMillisecondsSinceEpoch(0);
  void update(Peer incoming) {
    peer = incoming;
    signal.observe(incoming.lastSeen, incoming.rssi);
  }
}

class _Connection {
  _Connection(this.id, this.device, {required this.isCentral});
  final String id, device;
  final bool isCentral;
  final signal = HatTipSignal();
  DateTime lastSignalRead = DateTime.fromMillisecondsSinceEpoch(0);
  ({DateTime receivedAt, bool close})? sharedRange;
  bool? lastSignalClose;
  bool reportedMissingSignal = false;
  bool readingSignal = false;
  String? session, identity, team;
  DateTime lastHello = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime lastSeen = DateTime.now();
  Future<void> tail = Future.value();
  int incoming = 0;
  bool sending = false;
}
