import 'package:supabase_flutter/supabase_flutter.dart';
import '../map/campus_fix.dart';
import 'nearby_models.dart';

class SupabaseNearbyRepository implements NearbyRepository {
  SupabaseNearbyRepository(this.client);
  final SupabaseClient client;
  Future<dynamic> _call(String method, Map<String, dynamic> params) => client
      .rpc('sp_nearby_$method', params: params)
      .timeout(const Duration(seconds: 10));
  @override
  Future<NearbySession> open(String requestId) async {
    final data = Map<String, dynamic>.from(
      await _call('open', {'request_id': requestId}),
    );
    return NearbySession(
      data['token'] as String,
      NearbyConfig(Map<String, dynamic>.from(data['settings'])),
    );
  }

  @override
  Future<void> heartbeat(String session, CampusFix? fix) async {
    await _call('heartbeat', {
      'session_token': session,
      'latitude': fix?.point.latitude,
      'longitude': fix?.point.longitude,
      'accuracy_m': fix?.accuracy,
      'fix_at': fix?.timestamp.toUtc().toIso8601String(),
    });
  }

  @override
  Future<String?> challenge(String session, String peer) async =>
      await _call('challenge', {'session_token': session, 'peer_token': peer})
          as String?;
  @override
  Future<bool> confirm(String session, String nonce) async =>
      await _call('confirm', {'session_token': session, 'nonce': nonce}) ==
      true;
  @override
  Future<NearbySnapshot> read(String session) async {
    final watch = Stopwatch()..start();
    final data = Map<String, dynamic>.from(
      await _call('read', {'session_token': session}),
    );
    return decode(data, DateTime.now(), watch.elapsed);
  }

  /// Convert server deadlines into bounded local lifetimes, subtracting the full
  /// round trip. A response never grants a new lease to an old position.
  static NearbySnapshot decode(
    Map<String, dynamic> data,
    DateTime now,
    Duration transit,
  ) {
    final config = NearbyConfig(Map<String, dynamic>.from(data['settings']));
    final server = DateTime.parse(data['server_now']);
    DateTime? deadline(dynamic value, Duration maximum) {
      if (value is! String) return null;
      final until = DateTime.tryParse(value);
      if (until == null) return null;
      final remaining = until.difference(server) - transit;
      return remaining > Duration.zero && remaining <= maximum
          ? now.add(remaining)
          : null;
    }

    final peers = <NearbyPeer>[];
    for (final raw in data['players'] as List) {
      final row = Map<String, dynamic>.from(raw);
      final expires = deadline(row['expires_at'], config.lease);
      if (expires == null || row['id'] is! String || row['label'] is! String) {
        continue;
      }
      NearbyPosition? position;
      if (row['position'] case final Map fix) {
        final lat = fix['latitude'], lng = fix['longitude'];
        final accuracy = fix['accuracy_m'];
        final fresh = deadline(
          fix['expires_at'],
          config.fixAge + const Duration(seconds: 2),
        );
        if (lat is num &&
            lng is num &&
            accuracy is num &&
            lat.isFinite &&
            lng.isFinite &&
            lat.abs() <= 90 &&
            lng.abs() <= 180 &&
            accuracy >= 0 &&
            accuracy <= config.maxAccuracy &&
            fresh != null) {
          position = NearbyPosition(lat.toDouble(), lng.toDouble(), fresh);
        }
      }
      peers.add(NearbyPeer(row['id'], row['label'], expires, position));
      if (peers.length == config.maxPeers) break;
    }
    return NearbySnapshot(peers, config);
  }

  @override
  Future<void> close(String session) async {
    await _call('close', {'session_token': session});
  }
}
