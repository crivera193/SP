import 'dart:async';
import 'package:flutter/widgets.dart';
import '../map/campus_fix.dart';
import 'nearby_models.dart';

/// Owns one account's discovery session. GPS can update position data, never peers.
class NearbyController extends ChangeNotifier with WidgetsBindingObserver {
  NearbyController(
    this.repository,
    this.radio, {
    this.observeLifecycle = true,
  }) {
    if (observeLifecycle) {
      WidgetsBinding.instance.addObserver(this);
      final state = WidgetsBinding.instance.lifecycleState;
      _active = state == null || state == AppLifecycleState.resumed;
    }
  }
  final NearbyRepository repository;
  final NearbyRadio radio;
  final bool observeLifecycle;
  bool enabled = false, busy = false, running = false;
  bool _active = true, _disposed = false;
  int? _pollingEpoch;
  int _epoch = 0;
  String? error;
  NearbySession? _session;
  NearbyConfig? _config;
  CampusFix? _fix;
  List<NearbyPeer> _peers = const [];
  List<NearbyPeer> get peers => List.unmodifiable(_peers);
  Future<void> _tail = Future.value(), _cleanup = Future.value();
  Timer? _timer, _expiry;
  final Map<String, DateTime> _receipts = {};

  String get status =>
      error ??
      (busy
          ? 'Starting Bluetooth…'
          : !enabled
          ? 'Nearby players off'
          : !_active
          ? 'Nearby players paused'
          : !running
          ? 'Nearby players unavailable'
          : _peers.isEmpty
          ? 'Bluetooth on · no players detected'
          : '${_peers.length} nearby · ${_peers.where((p) => p.position != null).length} on map');

  Future<void> enable() {
    if (_disposed || busy || running) return Future.value();
    enabled = true;
    error = null;
    return _start();
  }

  Future<void> disable() {
    enabled = false;
    error = null;
    return _stop();
  }

  void updatePosition(CampusFix? fix) {
    _fix = fix;
  }

  bool _current(int epoch) =>
      !_disposed && enabled && _active && epoch == _epoch;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _start() {
    final epoch = ++_epoch;
    _tail = _tail.catchError((Object _) {}).then((_) async {
      await _cleanup;
      if (!_current(epoch)) return;
      busy = true;
      _notify();
      try {
        // Permissions are resolved before allocating a short server lease.
        await radio.prepare();
        if (!_current(epoch)) return;
        final session = await repository.open(NearbyProtocol.randomId());
        if (!_current(epoch)) {
          await repository.close(session.token);
          return;
        }
        _session = session;
        _config = session.config;
        await repository.heartbeat(session.token, _validFix());
        if (!_current(epoch)) return;
        await _startRadio(epoch);
        if (!_current(epoch)) return;
        running = true;
        busy = false;
        _notify();
        _expiry = Timer.periodic(const Duration(seconds: 1), (_) => expire());
        await refresh();
      } catch (e) {
        if (_current(epoch)) {
          await _fail(
            e is StateError
                ? e.message.toString()
                : 'Nearby players could not connect. Check internet and retry.',
          );
        }
      }
    });
    return _tail;
  }

  CampusFix? _validFix() {
    final fix = _fix, config = _config;
    return fix != null && config != null && config.accepts(fix, DateTime.now())
        ? fix
        : null;
  }

  Future<void> _startRadio(int epoch) => radio.start(
    _session!.token,
    _config!,
    (peer) async {
      final session = _session;
      if (!_current(epoch) || session == null) return null;
      try {
        final nonce = await repository.challenge(session.token, peer);
        return _current(epoch) ? nonce : null;
      } catch (_) {
        if (_current(epoch)) {
          unawaited(_fail('Nearby connection lost. Check internet and retry.'));
        }
        return null;
      }
    },
    (nonce) async {
      final session = _session, config = _config;
      if (!_current(epoch) || session == null || config == null) return;
      final now = DateTime.now();
      _receipts.removeWhere((_, at) => now.difference(at) > config.challenge);
      if (_receipts.containsKey(nonce) ||
          _receipts.length >= config.maxPeers * 2) {
        return;
      }
      _receipts[nonce] = now;
      try {
        final accepted = await repository.confirm(session.token, nonce);
        if (_current(epoch) && accepted && running) unawaited(refresh());
      } catch (_) {
        if (_current(epoch)) {
          unawaited(_fail('Nearby connection lost. Check internet and retry.'));
        }
      }
    },
    (message) {
      if (_current(epoch)) unawaited(_fail(message));
    },
  );

  Future<void> refresh() async {
    if (_pollingEpoch == _epoch || !running) return;
    final epoch = _epoch, session = _session;
    if (!_current(epoch) || session == null) return;
    _pollingEpoch = epoch;
    try {
      await repository.heartbeat(session.token, _validFix());
      if (!_current(epoch)) return;
      final snapshot = await repository.read(session.token);
      if (!_current(epoch)) return;
      final old = _config!;
      _config = snapshot.config;
      _peers = snapshot.peers;
      if (old.scan != _config!.scan ||
          old.pause != _config!.pause ||
          old.maxPeers != _config!.maxPeers ||
          old.heartbeat != _config!.heartbeat) {
        await _startRadio(epoch);
      }
      if (!_current(epoch)) return;
      expire();
      _notify();
    } catch (_) {
      if (_current(epoch)) {
        await _fail('Nearby connection lost. Check internet and retry.');
      }
    } finally {
      if (_pollingEpoch == epoch) _pollingEpoch = null;
      if (_current(epoch) && running) {
        _timer?.cancel();
        _timer = Timer(_config!.heartbeat, () => unawaited(refresh()));
      }
    }
  }

  void expire([DateTime? time]) {
    final now = time ?? DateTime.now();
    var changed = false;
    final kept = <NearbyPeer>[];
    for (final peer in _peers) {
      if (!peer.expiresAt.isAfter(now)) {
        changed = true;
        continue;
      }
      final p = peer.position;
      if (p != null && !p.expiresAt.isAfter(now)) {
        kept.add(peer.withoutPosition());
        changed = true;
      } else {
        kept.add(peer);
      }
    }
    if (changed) {
      _peers = kept;
      _notify();
    }
  }

  Future<void> _fail(String message) async {
    error = message;
    await _stop();
  }

  Future<void> _stop() async {
    _epoch++;
    _timer?.cancel();
    _expiry?.cancel();
    final session = _session;
    _session = null;
    _peers = const [];
    _fix = null;
    _receipts.clear();
    running = false;
    busy = false;
    _notify();
    final native = radio.stop().catchError((Object _) {});
    final server = session == null
        ? Future<void>.value()
        : repository
              .close(session.token)
              .catchError(
                (Object _) {},
              ); // A missed close is bounded by the server lease.
    _cleanup = Future.wait([_cleanup, native, server]).then((_) {});
    await _cleanup;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Sharing is conservative: only the visible, interactive app is active.
    final active = state == AppLifecycleState.resumed;
    if (active == _active) return;
    _active = active;
    if (!active) {
      unawaited(_stop());
    } else if (enabled && !_disposed) {
      error = null;
      unawaited(_start());
    }
  }

  Future<void> openSettings() => radio.openSettings();
  @override
  void dispose() {
    if (observeLifecycle) WidgetsBinding.instance.removeObserver(this);
    _disposed = true;
    unawaited(_stop());
    super.dispose();
  }
}
