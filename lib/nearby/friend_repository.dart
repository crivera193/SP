import 'dart:math';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'nearby_models.dart';
import 'friend_protocol.dart';

class SupabaseFriendRepository implements FriendRepository {
  SupabaseFriendRepository(this.client);
  final SupabaseClient client;
  Future<dynamic> _call(String name, Map<String, dynamic> args) =>
      client.rpc(name, params: args).timeout(const Duration(seconds: 10));
  @override
  Future<List<FriendEntry>> readFriends(String session) async {
    final row = await _call('sp_friends_read', {'session_token': session});
    return [
      for (final e in row['entries'] as List)
        FriendEntry(
          e['id'] as String,
          e['label'] as String,
          friendshipFrom(e['status']),
        ),
    ];
  }

  @override
  Future<void> requestFriend(String session, String peerId) async {
    await _call('sp_friends_request', {
      'session_token': session,
      'peer_id': peerId,
    });
  }

  @override
  Future<void> respondFriend(
    String session,
    String relationship,
    String action,
  ) async {
    await _call('sp_friends_respond', {
      'session_token': session,
      'relationship_id': relationship,
      'action': action,
    });
  }

  Future<FriendGrant?> _grant(String rpc, Map<String, dynamic> args) async {
    final watch = Stopwatch()..start();
    final row = await _call(rpc, args);
    return row == null
        ? null
        : FriendGrant.decode(
            Map<String, dynamic>.from(row as Map),
            watch.elapsed,
          );
  }

  @override
  Future<FriendGrant> openChannel(String session, String peerId) async {
    final random = Random.secure();
    final key = List.generate(
      32,
      (_) => random.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final grant = await _grant('sp_friend_channel_open', {
      'session_token': session,
      'peer_id': peerId,
      'request_id': NearbyProtocol.randomId(),
      'key_hex': key,
    });
    if (grant == null) throw StateError('Friend verification expired. Retry.');
    return grant;
  }

  @override
  Future<FriendGrant?> checkChannel(String session, String channel) => _grant(
    'sp_friend_channel_check',
    {'session_token': session, 'channel_id': channel},
  );
  @override
  Future<void> closeChannel(String session, String channel) async {
    await _call('sp_friend_channel_close', {
      'session_token': session,
      'channel_id': channel,
    });
  }
}
