import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

enum Friendship { none, incoming, outgoing, accepted }

Friendship friendshipFrom(dynamic value) => Friendship.values.firstWhere(
  (e) => e.name == value,
  orElse: () => Friendship.none,
);

class FriendEntry {
  const FriendEntry(this.id, this.label, this.status);
  final String id, label;
  final Friendship status;
}

class FriendGrant {
  const FriendGrant({
    required this.id,
    required this.peerToken,
    required this.peerId,
    required this.label,
    required this.keyHex,
    required this.relationshipId,
    required this.first,
    required this.expiresAt,
  });
  final String id, peerToken, peerId, label, keyHex, relationshipId;
  final bool first;
  final DateTime expiresAt;
  bool get live => expiresAt.isAfter(DateTime.now());
  factory FriendGrant.decode(Map<String, dynamic> row, Duration transit) {
    final remaining =
        DateTime.parse(
          row['expires_at'] as String,
        ).difference(DateTime.parse(row['server_now'] as String)) -
        transit;
    final key = row['key_hex'];
    if (key is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(key) ||
        row['first'] is! bool ||
        remaining <= Duration.zero ||
        remaining > const Duration(seconds: 120)) {
      throw const FormatException('Invalid friend authorization.');
    }
    return FriendGrant(
      id: row['id'] as String,
      peerToken: row['peer_token'] as String,
      peerId: row['peer_id'] as String,
      label: row['label'] as String,
      keyHex: key,
      relationshipId: row['relationship_id'] as String,
      first: row['first'] as bool,
      expiresAt: DateTime.now().add(remaining),
    );
  }
}

abstract interface class FriendRepository {
  Future<List<FriendEntry>> readFriends(String session);
  Future<void> requestFriend(String session, String peerId);
  Future<void> respondFriend(
    String session,
    String relationship,
    String action,
  );
  Future<FriendGrant> openChannel(String session, String peerId);
  Future<FriendGrant?> checkChannel(String session, String channel);
  Future<void> closeChannel(String session, String channel);
}

/// Offline transports identify the incoming peer from the fresh BLE discovery
/// exchange; the offer ID alone never supplies identity or permission.
abstract interface class FriendOfferRepository {
  Future<FriendGrant?> acceptOffer(
    String session,
    String channel,
    String? peerToken,
  );
}

class FriendPacket {
  FriendPacket(this.sequence, this.body, this.duplicate);
  final int sequence;
  final Map<String, dynamic> body;
  final bool duplicate;
}

/// AES-GCM authenticates the channel, direction, sequence and payload. Each fresh
/// channel has a fresh 256-bit key. Counters never reset within a channel.
class FriendCipher {
  FriendCipher(this.grant)
    : _key = SecretKey([
        for (var i = 0; i < grant.keyHex.length; i += 2)
          int.parse(grant.keyHex.substring(i, i + 2), radix: 16),
      ]);
  final FriendGrant grant;
  final SecretKey _key;
  final _algorithm = AesGcm.with256bits();
  final _seen = <int>{};
  int _sending = 0, _highest = -1;
  List<int> _nonce(int sequence, bool first) {
    final nonce = Uint8List(12);
    nonce[0] = first ? 0 : 1;
    ByteData.sublistView(nonce).setUint32(8, sequence);
    return nonce;
  }

  Future<Uint8List> encrypt(Map<String, dynamic> body) async {
    if (_sending >= 0xffffffff) {
      throw StateError('Reopen the Bluetooth session.');
    }
    final sequence = _sending++; // allocate before await: never reuse a nonce
    final box = await _algorithm.encrypt(
      utf8.encode(jsonEncode(body)),
      secretKey: _key,
      nonce: _nonce(sequence, grant.first),
      aad: utf8.encode('SP-friend-v1:${grant.id}'),
    );
    final packet = Uint8List(4 + box.cipherText.length + box.mac.bytes.length);
    ByteData.sublistView(packet).setUint32(0, sequence);
    packet.setAll(4, [...box.cipherText, ...box.mac.bytes]);
    if (packet.length > FriendWire.maxPacket) {
      throw StateError('Message is too long.');
    }
    return packet;
  }

  Future<FriendPacket> decrypt(Uint8List bytes) async {
    if (bytes.length < 21 || bytes.length > FriendWire.maxPacket) {
      throw const FormatException('Invalid protected message.');
    }
    final sequence = ByteData.sublistView(bytes).getUint32(0);
    if (sequence <= _highest - 64) {
      throw const FormatException('Expired message.');
    }
    final plain = await _algorithm.decrypt(
      SecretBox(
        bytes.sublist(4, bytes.length - 16),
        nonce: _nonce(sequence, !grant.first),
        mac: Mac(bytes.sublist(bytes.length - 16)),
      ),
      secretKey: _key,
      aad: utf8.encode('SP-friend-v1:${grant.id}'),
    );
    final body = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(plain)) as Map,
    );
    final duplicate = !_seen.add(sequence);
    if (sequence > _highest) _highest = sequence;
    _seen.removeWhere((s) => s <= _highest - 64);
    return FriendPacket(sequence, body, duplicate);
  }
}

class _Outgoing {
  _Outgoing(this.packet, this.transient);
  final Uint8List packet;
  final bool transient;
  int cursor = 0;
  int get sequence => ByteData.sublistView(packet).getUint32(0);
}

class _Assembly {
  _Assembly(this.total);
  final int total;
  final created = DateTime.now();
  final parts = <int, List<int>>{};
}

class _Mailbox {
  _Mailbox(this.grant);
  FriendGrant grant;
  final outgoing = Queue<_Outgoing>();
  final incoming = <int, _Assembly>{};
  bool processing = false;
}

/// Bounded, retransmittable baseline-ATT frames (20 bytes). Message ACKs are
/// encrypted; an untrusted central cannot acknowledge or read plaintext data.
/// The same mailbox is exercised by native GATT and the two-client test harness.
class FriendWire {
  static const maxPacket = 512;
  static const _chunk = 14;
  Future<bool> Function(String channel, String? peerToken)? onOffer;
  Future<void> Function(String channel, Uint8List packet)? onPacket;
  final _boxes = <String, _Mailbox>{};
  final _bindings = <String, String>{};
  final _offers = <String, Future<bool>>{};
  final _recentOffers = <String, DateTime>{};
  String? channelFor(String token) {
    for (final box in _boxes.values) {
      if (box.grant.peerToken == token && box.grant.live) return box.grant.id;
    }
    return null;
  }

  void attach(FriendGrant grant) {
    (_boxes[grant.id] ??= _Mailbox(grant)).grant = grant;
  }

  void detach(String id) {
    _boxes.remove(id);
    _bindings.removeWhere((_, channel) => channel == id);
  }

  void clear() {
    _boxes.clear();
    _bindings.clear();
    _recentOffers.clear();
  }

  Future<bool> offer(String id, String central, {String? peerToken}) async {
    if (_boxes[id]?.grant.live == true) {
      return _bind(id, central);
    }
    final pending = _offers[id];
    if (pending != null) return await pending && _bind(id, central);
    final now = DateTime.now();
    _recentOffers.removeWhere((_, at) => now.difference(at).inSeconds > 8);
    if (_offers.length >= 4 ||
        _recentOffers.length >= 24 ||
        _recentOffers.containsKey(id)) {
      return false;
    }
    _recentOffers[id] = now;
    final work = onOffer?.call(id, peerToken) ?? Future.value(false);
    _offers[id] = work;
    try {
      return await work && _bind(id, central);
    } finally {
      _offers.remove(id);
    }
  }

  bool _bind(String id, String central) {
    if (_boxes[id]?.grant.live != true) return false;
    if (_bindings.length >= 64 && !_bindings.containsKey(central)) {
      _bindings.remove(_bindings.keys.first);
    }
    _bindings[central] = id;
    return true;
  }

  void queue(String id, Uint8List packet, {bool transient = false}) {
    final box = _boxes[id];
    if (box == null || !box.grant.live) {
      throw StateError('Bluetooth session expired.');
    }
    if (packet.length < 21 || packet.length > maxPacket) {
      throw const FormatException('Invalid protected packet.');
    }
    final sequence = ByteData.sublistView(packet).getUint32(0);
    if (box.outgoing.any((p) => p.sequence == sequence)) return;
    if (box.outgoing.length >= 12) {
      throw StateError('Wait for pending Bluetooth messages to arrive.');
    }
    box.outgoing.add(_Outgoing(Uint8List.fromList(packet), transient));
  }

  void acknowledge(String id, int sequence) =>
      _boxes[id]?.outgoing.removeWhere((p) => p.sequence == sequence);
  Uint8List next(String id) {
    final box = _boxes[id];
    if (box == null || !box.grant.live || box.outgoing.isEmpty) {
      return Uint8List(0);
    }
    final item = box.outgoing.first;
    final total = (item.packet.length / _chunk).ceil();
    final index = item.cursor++;
    final start = index * _chunk;
    final end = (start + _chunk).clamp(0, item.packet.length);
    final frame = Uint8List(6 + end - start);
    ByteData.sublistView(frame).setUint32(0, item.sequence);
    frame[4] = index;
    frame[5] = total;
    frame.setAll(6, item.packet.sublist(start, end));
    if (item.cursor == total) {
      box.outgoing.removeFirst();
      item.cursor = 0;
      if (!item.transient) box.outgoing.add(item);
    }
    return frame;
  }

  Uint8List read(String central) => next(_bindings[central] ?? '');
  Future<void> receiveFrom(String central, Uint8List frame) =>
      receive(_bindings[central] ?? '', frame);
  Future<void> receive(String id, Uint8List frame) async {
    final box = _boxes[id];
    if (box == null ||
        !box.grant.live ||
        frame.length < 7 ||
        frame.length > 20) {
      return;
    }
    final sequence = ByteData.sublistView(frame).getUint32(0);
    final index = frame[4], total = frame[5];
    if (total < 2 ||
        total > (maxPacket / _chunk).ceil() ||
        index >= total ||
        (index < total - 1 && frame.length != 20)) {
      return;
    }
    box.incoming.removeWhere(
      (_, a) => DateTime.now().difference(a.created).inSeconds > 10,
    );
    if (!box.incoming.containsKey(sequence) && box.incoming.length >= 4) return;
    final assembly = box.incoming.putIfAbsent(sequence, () => _Assembly(total));
    if (assembly.total != total) {
      box.incoming.remove(sequence);
      return;
    }
    assembly.parts[index] = frame.sublist(6);
    if (assembly.parts.length != total) return;
    box.incoming.remove(sequence);
    final packet = Uint8List.fromList([
      for (var i = 0; i < total; i++) ...assembly.parts[i]!,
    ]);
    if (packet.length > maxPacket ||
        packet.length < 4 ||
        ByteData.sublistView(packet).getUint32(0) != sequence) {
      return;
    }
    if (box.processing) return;
    box.processing = true;
    try {
      await onPacket?.call(id, packet);
    } finally {
      box.processing = false;
    }
  }
}
