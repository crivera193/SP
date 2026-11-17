import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'friend_protocol.dart';
import 'nearby_models.dart';
import 'offline_nearby_repository.dart';

/// Never calls Supabase. The pairing key was verified in normal account setup;
/// each open derives a new key using fresh BLE sessions plus a random offer ID.
class OfflineFriendRepository
    implements FriendRepository, FriendOfferRepository {
  OfflineFriendRepository(this.nearby);
  final OfflineNearbyRepository nearby;
  final _channels = <String, FriendGrant>{};
  @override
  Future<List<FriendEntry>> readFriends(String session) async => [
    for (final f in nearby.book.friends)
      if (f.status == Friendship.accepted) FriendEntry(f.id, f.label, f.status),
  ];
  Future<FriendGrant?> _derive(String session, String id, String? peer) async {
    if (nearby.active != session || peer == null || !nearby.fresh(peer)) {
      return null;
    }
    final code = nearby.identities[peer];
    final friend = code == null ? null : nearby.book.byCode(code);
    if (friend == null) return null;
    final sessions = [session, peer]..sort();
    final key = friend.keyHex!;
    final mac = await Hmac.sha256().calculateMac(
      utf8.encode(
        'SP-offline-v2|${friend.id}|${sessions[0]}|${sessions[1]}|$id',
      ),
      secretKey: SecretKey([
        for (var i = 0; i < key.length; i += 2)
          int.parse(key.substring(i, i + 2), radix: 16),
      ]),
    );
    if (nearby.active != session ||
        !nearby.fresh(peer) ||
        nearby.book.byCode(code!) != friend) {
      return null;
    }
    final until = nearby.deadline(peer)!;
    return FriendGrant(
      id: id,
      peerToken: peer,
      peerId: peer,
      label: friend.label,
      relationshipId: friend.id,
      keyHex: mac.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      first: session.compareTo(peer) < 0,
      expiresAt: !nearby.book.durable && nearby.book.expiresAt!.isBefore(until)
          ? nearby.book.expiresAt!
          : until,
    );
  }

  @override
  Future<FriendGrant> openChannel(String session, String peerId) async {
    final grant = await _derive(session, NearbyProtocol.randomId(), peerId);
    if (grant == null) {
      throw StateError('This nearby player is not a verified friend.');
    }
    _channels[grant.id] = grant;
    return grant;
  }

  @override
  Future<FriendGrant?> acceptOffer(
    String session,
    String channel,
    String? peerToken,
  ) async {
    final grant = await _derive(session, channel, peerToken);
    if (grant != null) _channels[channel] = grant;
    return grant;
  }

  @override
  Future<FriendGrant?> checkChannel(String session, String channel) async {
    final old = _channels[channel];
    if (old == null) return null;
    final grant = await _derive(session, channel, old.peerToken);
    if (grant == null) {
      _channels.remove(channel);
    } else {
      _channels[channel] = grant;
    }
    return grant;
  }

  @override
  Future<void> closeChannel(String session, String channel) async {
    _channels.remove(channel);
  }

  @override
  Future<void> requestFriend(String session, String peerId) async {
    throw StateError(
      'Manage verified friends from Friends, outside Bluetooth.',
    );
  }

  @override
  Future<void> respondFriend(
    String session,
    String relationship,
    String action,
  ) async {
    throw StateError(
      'Manage verified friends from Friends, outside Bluetooth.',
    );
  }
}
