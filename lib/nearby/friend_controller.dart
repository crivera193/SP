import 'dart:async';
import 'package:flutter/foundation.dart';
import 'friend_protocol.dart';

class FriendConversation {
  FriendConversation(this.grant) : cipher = FriendCipher(grant);
  FriendGrant grant;
  final FriendCipher cipher;
  bool ready = false;
  final acknowledgements = <int, Uint8List>{};
  Future<void> tail = Future.value();
  int? pendingPosition;
  bool closing = false;
  int? closingSequence;
  Timer? closingTimer;
}

/// Account-scoped authorization through the injected repository. Production uses
/// only the local verified friend book and fresh BLE evidence, never HTTP/RPC.
class FriendController extends ChangeNotifier {
  FriendController(
    this.repository,
    this.wire, {
    this.localPosition,
    this.onPosition,
  }) {
    wire.onOffer = _accept;
    wire.onPacket = _receive;
  }
  final FriendRepository repository;
  final FriendWire wire;
  final Map<String, dynamic>? Function()? localPosition;
  final void Function(String peer, Map<String, dynamic>? fix)? onPosition;
  final _channels = <String, FriendConversation>{};
  final _closed = <String>{};
  List<FriendEntry> entries = const [];
  List<FriendConversation> get conversations =>
      List.unmodifiable(_channels.values.where((c) => !c.closing));
  String? error, _session;
  bool busy = false, _disposed = false, _refreshing = false;
  int _epoch = 0;
  bool _current(int epoch) => !_disposed && _session != null && epoch == _epoch;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void begin(String session) {
    if (_session == session) return;
    _epoch++;
    _session = session;
    for (final c in _channels.values) {
      c.closingTimer?.cancel();
    }
    _channels.clear();
    _closed.clear();
    wire.clear();
    entries = const [];
    error = null;
    busy = false;
    _refreshing = false;
    _notify();
  }

  FriendConversation? conversationFor(String peer) {
    for (final c in _channels.values) {
      if (c.grant.peerId == peer && !c.closing) return c;
    }
    return null;
  }

  Future<void> refresh() async {
    if (_session == null || _refreshing) return;
    final epoch = _epoch, session = _session!;
    _refreshing = true;
    try {
      final rows = await repository.readFriends(session);
      if (!_current(epoch)) return;
      entries = rows;
      error = null;
      for (final channel in _channels.values.toList()) {
        if (channel.closing) continue;
        if (await _authorize(channel, epoch) &&
            channel.ready &&
            localPosition != null &&
            channel.pendingPosition == null) {
          await _serial(channel, () async {
            final bytes = await channel.cipher.encrypt({
              'type': 'position',
              'fix': localPosition!(),
            });
            if (!_current(epoch) || _channels[channel.grant.id] != channel) {
              return;
            }
            wire.queue(channel.grant.id, bytes);
            channel.pendingPosition = ByteData.sublistView(bytes).getUint32(0);
          });
        }
      }
      _notify();
    } catch (_) {
      if (_current(epoch)) {
        error =
            'Friend credentials unavailable. Refresh your list from Friends.';
        for (final id in _channels.keys.toList()) {
          _drop(id);
        }
        _notify();
      }
    } finally {
      if (_current(epoch)) _refreshing = false;
    }
  }

  Future<void> _action(Future<void> Function(String) action) async {
    if (busy || _session == null) return;
    final epoch = _epoch;
    busy = true;
    error = null;
    _notify();
    try {
      await action(_session!);
      if (_current(epoch)) await refresh();
    } catch (_) {
      if (_current(epoch)) {
        error =
            'Could not verify that action. Refresh nearby players and retry.';
      }
    } finally {
      if (_current(epoch)) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> request(String peer) =>
      _action((s) => repository.requestFriend(s, peer));
  Future<void> respond(String relationship, String action) => _action((
    s,
  ) async {
    // Withdrawing local access is immediate, even if the network request fails.
    if (action == 'remove') {
      for (final c in _channels.values.toList()) {
        if (c.grant.relationshipId == relationship) _drop(c.grant.id);
      }
    }
    await repository.respondFriend(s, relationship, action);
  });
  Future<void> open(String peer) => _action((s) async {
    if (conversationFor(peer) != null) return;
    final epoch = _epoch;
    final grant = await repository.openChannel(s, peer);
    if (!_current(epoch)) {
      await repository.closeChannel(s, grant.id);
      return;
    }
    await _attach(grant, epoch);
  });
  Future<bool> _accept(String id, String? peerToken) async {
    if (_session == null || _closed.contains(id) || _channels.length >= 24) {
      return false;
    }
    final epoch = _epoch;
    try {
      final grant = repository is FriendOfferRepository
          ? await (repository as FriendOfferRepository).acceptOffer(
              _session!,
              id,
              peerToken,
            )
          : await repository.checkChannel(_session!, id);
      if (!_current(epoch) || grant == null || _closed.contains(id)) {
        return false;
      }
      await _attach(grant, epoch);
      return _current(epoch) && _channels.containsKey(id);
    } catch (_) {
      return false;
    }
  }

  Future<void> _attach(FriendGrant grant, int epoch) async {
    if (!_current(epoch) || !grant.live || _closed.contains(grant.id)) return;
    if (_channels.containsKey(grant.id)) return; // preserve nonce/replay state
    final channel = FriendConversation(grant);
    _channels[grant.id] = channel;
    wire.attach(grant);
    final hello = await channel.cipher.encrypt({'type': 'hello'});
    if (!_current(epoch) || _channels[grant.id] != channel) return;
    wire.queue(grant.id, hello);
    _notify();
  }

  Future<bool> _authorize(FriendConversation channel, int epoch) async {
    if (!_current(epoch) || _channels[channel.grant.id] != channel) {
      return false;
    }
    FriendGrant? grant;
    try {
      grant = await repository.checkChannel(_session!, channel.grant.id);
    } catch (_) {
      if (_current(epoch)) {
        _drop(channel.grant.id);
        error =
            'Friend credentials unavailable. Refresh your list from Friends.';
        _notify();
      }
      rethrow;
    }
    if (!_current(epoch) || _channels[channel.grant.id] != channel) {
      return false;
    }
    if (grant == null ||
        !grant.live ||
        grant.keyHex != channel.grant.keyHex ||
        grant.first != channel.grant.first ||
        grant.relationshipId != channel.grant.relationshipId ||
        grant.peerToken != channel.grant.peerToken) {
      _drop(channel.grant.id);
      error =
          'Bluetooth session closed. Your friend must be nearby with valid friend credentials.';
      _notify();
      return false;
    }
    channel.grant = grant;
    wire.attach(grant);
    return true;
  }

  Future<void> _serial(FriendConversation c, Future<void> Function() work) {
    final next = c.tail.then((_) => work());
    c.tail = next.catchError((Object _) {});
    return next;
  }

  Future<void> _receive(String id, Uint8List bytes) async {
    final c = _channels[id];
    if (c == null) return;
    final epoch = _epoch;
    try {
      await _serial(c, () async {
        final packet = await c.cipher.decrypt(bytes);
        final type = packet.body['type'];
        if (c.closing) {
          if (!c.grant.live || (type != 'ack' && type != 'close')) return;
        } else if (!await _authorize(c, epoch)) {
          return;
        }
        if (!_current(epoch) || _channels[id] != c) return;
        if (type == 'ack') {
          final sequence = packet.body['sequence'];
          if (sequence is! int || sequence < 0) return;
          wire.acknowledge(id, sequence);
          if (c.closingSequence == sequence) {
            _drop(id);
            _notify();
            return;
          }
          if (c.pendingPosition == sequence) c.pendingPosition = null;
          _notify();
          return;
        }
        if (type != 'hello' && type != 'position' && type != 'close') {
          return;
        }
        if (type == 'position' &&
            (!c.ready ||
                (packet.body['fix'] != null && packet.body['fix'] is! Map))) {
          return;
        }
        // Retrying a lost ACK never delivers an application message twice.
        if (!packet.duplicate) {
          if (type == 'close') {
            _armClose(c);
          } else if (type == 'hello') {
            c.ready = true;
          } else if (type == 'position') {
            onPosition?.call(
              c.grant.peerId,
              packet.body['fix'] == null
                  ? null
                  : Map<String, dynamic>.from(packet.body['fix'] as Map),
            );
          }
        }
        var ack = c.acknowledgements[packet.sequence];
        if (ack == null) {
          ack = await c.cipher.encrypt({
            'type': 'ack',
            'sequence': packet.sequence,
          });
          c.acknowledgements[packet.sequence] = ack;
          if (c.acknowledgements.length > 64) {
            c.acknowledgements.remove(c.acknowledgements.keys.first);
          }
        }
        if (!_current(epoch) || _channels[id] != c) return;
        wire.queue(id, ack, transient: true);
        _notify();
      });
    } catch (_) {
      // Forged/corrupt frames are discarded; they never produce a message.
      // Authorization failures close access immediately, even while offline.
      if (_current(epoch) && !c.grant.live) {
        _drop(id);
        _notify();
      }
    }
  }

  Future<void> close(String id) async {
    final c = _channels[id];
    if (c == null || c.closing) return;
    final epoch = _epoch;
    await _serial(c, () async {
      if (!_current(epoch) || _channels[id] != c) return;
      _armClose(c);
      _notify();
      try {
        final bytes = await c.cipher.encrypt({'type': 'close'});
        if (!_current(epoch) || _channels[id] != c) return;
        c.closingSequence = ByteData.sublistView(bytes).getUint32(0);
        wire.queue(id, bytes);
      } catch (_) {
        _drop(id);
      }
    });
  }

  void _armClose(FriendConversation c) {
    c.closing = true;
    c.ready = false;
    c.closingTimer ??= Timer(
      c.grant.expiresAt.difference(DateTime.now()).isNegative
          ? Duration.zero
          : c.grant.expiresAt.difference(DateTime.now()),
      () {
        _drop(c.grant.id);
        _notify();
      },
    );
  }

  Future<void> _drop(String id) {
    final channel = _channels.remove(id), session = _session;
    channel?.closingTimer?.cancel();
    wire.detach(id);
    _closed.add(id);
    // Release the old server grant too, so a recovered encounter can open a
    // fresh key immediately instead of waiting for the abandoned grant's TTL.
    return channel == null || session == null
        ? Future<void>.value()
        : repository.closeChannel(session, id).catchError((Object _) {});
  }

  void expire({Set<String>? nearby}) {
    var changed = false;
    for (final c in _channels.values.toList()) {
      if (!c.grant.live ||
          (nearby != null && !nearby.contains(c.grant.peerId))) {
        _drop(c.grant.id);
        changed = true;
      }
    }
    if (changed) _notify();
  }

  Future<void> suspend() async {
    final session = _session, ids = _channels.keys.toList();
    _epoch++;
    _session = null;
    busy = false;
    _refreshing = false;
    for (final c in _channels.values) {
      c.closingTimer?.cancel();
    }
    _channels.clear();
    _closed.clear();
    entries = const [];
    error = null;
    wire.clear();
    _notify();
    if (session != null) {
      await Future.wait(
        ids.map(
          (id) =>
              repository.closeChannel(session, id).catchError((Object _) {}),
        ),
      );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(suspend());
    super.dispose();
  }
}
