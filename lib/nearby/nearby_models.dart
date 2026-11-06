import 'dart:math';
import '../map/campus_fix.dart';

/// Protocol identifiers are random capabilities, never emails, MACs or Auth JWTs.
abstract final class NearbyProtocol {
  static const service = '8c56b84b-4f58-47ba-ae42-39bcc8fe7001';
  static const session = '8c56b84b-4f58-47ba-ae42-39bcc8fe7002';
  static const challenge = '8c56b84b-4f58-47ba-ae42-39bcc8fe7003';
  static String randomId() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}

class NearbyConfig {
  NearbyConfig(Map<String, dynamic> json)
    : heartbeat = _duration(json, 'heartbeat_s', 3, 10),
      lease = _duration(json, 'lease_s', 15, 60),
      encounter = _duration(json, 'encounter_s', 10, 40),
      challenge = _duration(json, 'challenge_s', 5, 15),
      fixAge = _duration(json, 'fix_s', 3, 20),
      scan = _duration(json, 'scan_s', 10, 40),
      pause = _duration(json, 'pause_s', 3, 15),
      maxAccuracy = _integer(json, 'max_accuracy_m', 5, 40),
      maxPeers = _integer(json, 'max_peers', 1, 24) {
    if (json['enabled'] != true ||
        lease < heartbeat * 3 ||
        encounter < heartbeat * 2) {
      throw const FormatException('Nearby players are unavailable.');
    }
  }
  final Duration heartbeat, lease, encounter, challenge, fixAge, scan, pause;
  final int maxAccuracy, maxPeers;
  static int _integer(Map<String, dynamic> json, String key, int min, int max) {
    final v = json[key];
    if (v is! int || v < min || v > max) {
      throw const FormatException('Invalid nearby settings.');
    }
    return v;
  }

  static Duration _duration(
    Map<String, dynamic> json,
    String key,
    int min,
    int max,
  ) => Duration(seconds: _integer(json, key, min, max));
  bool accepts(CampusFix fix, DateTime now) =>
      fix.accuracy.isFinite &&
      fix.accuracy >= 0 &&
      fix.accuracy <= maxAccuracy &&
      fix.point.latitude.isFinite &&
      fix.point.latitude.abs() <= 90 &&
      fix.point.longitude.isFinite &&
      fix.point.longitude.abs() <= 180 &&
      now.difference(fix.timestamp) <= fixAge &&
      fix.timestamp.difference(now) <= const Duration(seconds: 2);
}

class NearbySession {
  const NearbySession(this.token, this.config);
  final String token;
  final NearbyConfig config;
}

class NearbyPosition {
  const NearbyPosition(this.latitude, this.longitude, this.expiresAt);
  final double latitude, longitude;
  final DateTime expiresAt;
}

class NearbyPeer {
  const NearbyPeer(this.id, this.label, this.expiresAt, this.position);
  final String id, label;
  final DateTime expiresAt;
  final NearbyPosition? position;
  NearbyPeer withoutPosition() => NearbyPeer(id, label, expiresAt, null);
}

class NearbySnapshot {
  const NearbySnapshot(this.peers, this.config);
  final List<NearbyPeer> peers;
  final NearbyConfig config;
}

abstract interface class NearbyRepository {
  Future<NearbySession> open(String requestId);
  Future<void> heartbeat(String session, CampusFix? fix);
  Future<String?> challenge(String session, String peer);
  Future<bool> confirm(String session, String nonce);
  Future<NearbySnapshot> read(String session);
  Future<void> close(String session);
}

abstract interface class NearbyRadio {
  Future<void> prepare();
  Future<void> start(
    String session,
    NearbyConfig config,
    Future<String?> Function(String peer) challenge,
    Future<void> Function(String nonce) confirm,
    void Function(String message) onFailure,
  );
  Future<void> stop();
  Future<void> openSettings();
}
