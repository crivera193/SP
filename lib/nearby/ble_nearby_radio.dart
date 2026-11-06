import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:geolocator/geolocator.dart' as gps;
import 'nearby_models.dart';

/// Android/iOS share an app-only service UUID and two baseline ATT characteristics.
/// Each value is exactly 16 bytes, below the baseline 20-byte write payload.
class BleNearbyRadio implements NearbyRadio {
  final _service = UUID.fromString(NearbyProtocol.service);
  final _sessionId = UUID.fromString(NearbyProtocol.session);
  final _challengeId = UUID.fromString(NearbyProtocol.challenge);
  CentralManager? _central;
  PeripheralManager? _peripheral;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final Map<UUID, Peripheral> _known = {};
  final Map<UUID, DateTime> _attempted = {};
  Future<void> _nativeTail = Future.value();
  Future<void>? _exchangeWork;
  Peripheral? _connecting;
  Timer? _scanTimer, _exchangeTimer;
  int _epoch = 0;
  bool _active = false;
  String? _token;
  NearbyConfig? _config;
  Future<String?> Function(String)? _challenge;
  Future<void> Function(String)? _confirm;
  void Function(String)? _failure;

  Future<void> _native(Future<void> Function() body) {
    final next = _nativeTail.then((_) => body());
    _nativeTail = next.catchError((Object _) {});
    return next;
  }

  bool _current(int epoch) => _active && epoch == _epoch;
  @override
  Future<void> prepare() async {
    final epoch = _epoch;
    if (!Platform.isAndroid && !Platform.isIOS) {
      throw StateError('Nearby players need an Android phone or iPhone.');
    }
    if (Platform.isAndroid) {
      // Android scan permission rules can require location permission. This does
      // not read coordinates or make GPS a player-discovery signal.
      var permission = await gps.Geolocator.checkPermission();
      if (epoch != _epoch) return;
      if (permission == gps.LocationPermission.denied) {
        permission = await gps.Geolocator.requestPermission();
      }
      if (epoch != _epoch) return;
      if (permission == gps.LocationPermission.denied ||
          permission == gps.LocationPermission.deniedForever) {
        throw StateError(
          'Allow location access in Settings for Android scanning and map positions.',
        );
      }
    }
    _central ??= CentralManager();
    _peripheral ??= PeripheralManager();
    await _ready(_central!, epoch, authorize: Platform.isAndroid);
    if (epoch != _epoch) return;
    await _ready(_peripheral!, epoch, authorize: Platform.isAndroid);
  }

  Future<void> _ready(
    BluetoothLowEnergyManager manager,
    int epoch, {
    bool authorize = false,
  }) async {
    var state = manager.state;
    if (state == BluetoothLowEnergyState.unknown) {
      state =
          (await manager.stateChanged
                  .firstWhere((e) => e.state != BluetoothLowEnergyState.unknown)
                  .timeout(const Duration(seconds: 45)))
              .state;
    }
    if (epoch != _epoch) return;
    if (authorize && state == BluetoothLowEnergyState.unauthorized) {
      final allowed = await manager.authorize();
      if (epoch != _epoch) return;
      if (!allowed) {
        throw StateError('Allow Nearby devices in Settings, then retry.');
      }
      state = manager.state;
      if (state == BluetoothLowEnergyState.unauthorized ||
          state == BluetoothLowEnergyState.unknown) {
        state =
            (await manager.stateChanged
                    .firstWhere(
                      (e) =>
                          e.state != BluetoothLowEnergyState.unknown &&
                          e.state != BluetoothLowEnergyState.unauthorized,
                    )
                    .timeout(const Duration(seconds: 10)))
                .state;
      }
    }
    if (epoch != _epoch) return;
    if (state != BluetoothLowEnergyState.poweredOn) {
      throw StateError(switch (state) {
        BluetoothLowEnergyState.unsupported =>
          'This device cannot advertise nearby players over Bluetooth.',
        BluetoothLowEnergyState.unauthorized =>
          'Allow Bluetooth access in Settings, then retry.',
        _ => 'Turn on Bluetooth, then retry Nearby players.',
      });
    }
  }

  @override
  Future<void> start(
    String session,
    NearbyConfig config,
    Future<String?> Function(String) challenge,
    Future<void> Function(String) confirm,
    void Function(String) onFailure,
  ) async {
    final nextEpoch = _epoch + 1;
    await stop();
    if (_epoch != nextEpoch) return;
    final epoch = _epoch;
    final central = _central, peripheral = _peripheral;
    if (central == null || peripheral == null) {
      throw StateError('Bluetooth is not ready. Retry Nearby players.');
    }
    await _ready(central, epoch);
    await _ready(peripheral, epoch);
    if (_epoch != epoch) return;
    _active = true;
    _token = session;
    _config = config;
    _challenge = challenge;
    _confirm = confirm;
    _failure = onFailure;
    void state(BluetoothLowEnergyStateChangedEventArgs e) {
      if (_current(epoch) && e.state != BluetoothLowEnergyState.poweredOn) {
        _failure?.call(
          'Bluetooth is unavailable. Check permissions and retry.',
        );
      }
    }

    _subscriptions.add(central.stateChanged.listen(state));
    _subscriptions.add(peripheral.stateChanged.listen(state));
    _subscriptions.add(
      central.discovered.listen((e) {
        if (!_current(epoch) ||
            !e.advertisement.serviceUUIDs.contains(_service)) {
          return;
        }
        if (_known.containsKey(e.peripheral.uuid) ||
            _known.length < config.maxPeers) {
          _known[e.peripheral.uuid] = e.peripheral;
          unawaited(_exchange());
        }
      }),
    );
    _subscriptions.add(
      peripheral.characteristicReadRequested.listen(
        (e) => unawaited(_read(e, epoch)),
      ),
    );
    _subscriptions.add(
      peripheral.characteristicWriteRequested.listen(
        (e) => unawaited(_write(e, epoch)),
      ),
    );
    await _native(() async {
      if (!_current(epoch)) return;
      await peripheral.removeAllServices();
      if (!_current(epoch)) return;
      await peripheral.addService(
        GATTService(
          uuid: _service,
          isPrimary: true,
          includedServices: [],
          characteristics: [
            GATTCharacteristic.mutable(
              uuid: _sessionId,
              properties: [GATTCharacteristicProperty.read],
              permissions: [GATTCharacteristicPermission.read],
              descriptors: [],
            ),
            GATTCharacteristic.mutable(
              uuid: _challengeId,
              properties: [GATTCharacteristicProperty.write],
              permissions: [GATTCharacteristicPermission.write],
              descriptors: [],
            ),
          ],
        ),
      );
      if (!_current(epoch)) return;
      // Only the fixed service is advertised: no device name, GPS, email or JWT.
      await peripheral.startAdvertising(
        Advertisement(serviceUUIDs: [_service]),
      );
    });
    if (!_current(epoch)) return;
    await _scan(epoch);
    if (!_current(epoch)) return;
    _exchangeTimer = Timer.periodic(
      config.heartbeat,
      (_) => unawaited(_exchange()),
    );
  }

  Future<void> _scan(int epoch) async {
    if (!_current(epoch)) return;
    try {
      await _native(() async {
        if (_current(epoch)) {
          await _central!.startDiscovery(serviceUUIDs: [_service]);
        }
      });
      if (!_current(epoch)) return;
      _scanTimer = Timer(_config!.scan, () async {
        try {
          await _native(() async {
            if (_current(epoch)) await _central!.stopDiscovery();
          });
          if (_current(epoch)) {
            _scanTimer = Timer(_config!.pause, () => unawaited(_scan(epoch)));
          }
        } catch (_) {
          if (_current(epoch)) {
            _failure?.call('Bluetooth scanning stopped. Retry Nearby players.');
          }
        }
      });
    } catch (_) {
      if (_current(epoch)) {
        _failure?.call('Bluetooth scanning failed. Retry Nearby players.');
      }
    }
  }

  Future<void> _read(
    GATTCharacteristicReadRequestedEventArgs e,
    int epoch,
  ) async {
    final peripheral = _peripheral!;
    try {
      if (!_current(epoch) ||
          e.characteristic.uuid != _sessionId ||
          _token == null) {
        await peripheral.respondReadRequestWithError(
          e.request,
          error: GATTError.readNotPermitted,
        );
        return;
      }
      final bytes = UUID.fromString(_token!).value;
      if (e.request.offset < 0 || e.request.offset > bytes.length) {
        await peripheral.respondReadRequestWithError(
          e.request,
          error: GATTError.invalidOffset,
        );
        return;
      }
      await peripheral.respondReadRequestWithValue(
        e.request,
        value: Uint8List.fromList(bytes.sublist(e.request.offset)),
      );
    } catch (_) {
      /* Disconnects cannot create encounters. */
    }
  }

  Future<void> _write(
    GATTCharacteristicWriteRequestedEventArgs e,
    int epoch,
  ) async {
    try {
      if (!_current(epoch) ||
          e.characteristic.uuid != _challengeId ||
          e.request.offset != 0 ||
          e.request.value.length != 16) {
        await _peripheral!.respondWriteRequestWithError(
          e.request,
          error: GATTError.invalidAttributeValueLength,
        );
        return;
      }
      final nonce = UUID(e.request.value).toString();
      await _peripheral!.respondWriteRequest(e.request);
      if (_current(epoch)) unawaited(_confirm!(nonce));
    } catch (_) {
      /* Incomplete requests cannot create encounters. */
    }
  }

  Future<void> _exchange() =>
      _exchangeWork ??= _exchangeNow().whenComplete(() => _exchangeWork = null);
  Future<void> _exchangeNow() async {
    if (!_active) return;
    final epoch = _epoch;
    // One outgoing link at a time, in fair oldest-attempt order. Incoming GATT
    // writes remain independent, so one link establishes a bilateral encounter.
    final peers = _known.values.toList()
      ..sort(
        (a, b) => (_attempted[a.uuid] ?? DateTime.fromMillisecondsSinceEpoch(0))
            .compareTo(
              _attempted[b.uuid] ?? DateTime.fromMillisecondsSinceEpoch(0),
            ),
      );
    for (final peer in peers) {
      if (!_current(epoch)) return;
      final previous = _attempted[peer.uuid];
      if (previous != null &&
          DateTime.now().difference(previous) < _config!.heartbeat) {
        continue;
      }
      _attempted[peer.uuid] = DateTime.now();
      _connecting = peer;
      try {
        await _central!.connect(peer).timeout(const Duration(seconds: 4));
        if (!_current(epoch)) return;
        final services = await _central!
            .discoverGATT(peer)
            .timeout(const Duration(seconds: 4));
        if (!_current(epoch)) return;
        final characteristics = services
            .where((s) => s.uuid == _service)
            .expand((s) => s.characteristics)
            .toList();
        final source = characteristics.firstWhere((c) => c.uuid == _sessionId);
        final destination = characteristics.firstWhere(
          (c) => c.uuid == _challengeId,
        );
        final bytes = await _central!
            .readCharacteristic(peer, source)
            .timeout(const Duration(seconds: 3));
        if (!_current(epoch) || bytes.length != 16) continue;
        final token = UUID(bytes).toString();
        if (token == _token) continue;
        final nonce = await _challenge!(token);
        if (!_current(epoch) || nonce == null) continue;
        await _central!
            .writeCharacteristic(
              peer,
              destination,
              value: Uint8List.fromList(UUID.fromString(nonce).value),
              type: GATTCharacteristicWriteType.withResponse,
            )
            .timeout(const Duration(seconds: 3));
      } catch (_) {
        _known.remove(peer.uuid);
        _attempted.remove(peer.uuid);
      } finally {
        try {
          await _central!.disconnect(peer).timeout(const Duration(seconds: 2));
        } catch (_) {
          /* Already disconnected. */
        }
        _connecting = null;
      }
    }
  }

  @override
  Future<void> stop() async {
    _active = false;
    _epoch++;
    _token = null;
    _scanTimer?.cancel();
    _exchangeTimer?.cancel();
    _known.clear();
    _attempted.clear();
    final subscriptions = _subscriptions.toList();
    _subscriptions.clear();
    for (final sub in subscriptions) {
      await sub.cancel();
    }
    final peer = _connecting;
    if (peer != null) {
      try {
        await _central?.disconnect(peer).timeout(const Duration(seconds: 2));
      } catch (_) {
        /* No active link. */
      }
    }
    await _native(() async {
      try {
        await _central?.stopDiscovery();
      } catch (_) {
        /* Radio unavailable. */
      }
      try {
        await _peripheral?.stopAdvertising();
      } catch (_) {
        /* Radio unavailable. */
      }
      try {
        await _peripheral?.removeAllServices();
      } catch (_) {
        /* Radio unavailable. */
      }
    });
    await _exchangeWork;
  }

  @override
  Future<void> openSettings() async {
    if (_central != null) await _central!.showAppSettings();
  }
}
