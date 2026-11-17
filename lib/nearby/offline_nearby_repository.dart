import '../map/campus_fix.dart';
import '../map/campus_geography.dart';
import 'friend_protocol.dart';
import 'nearby_models.dart';
import 'verified_friend_book.dart';

/// No network capabilities. Only fresh native GATT exchanges may call observe.
class OfflineNearbyRepository implements NearbyRepository {
  OfflineNearbyRepository(this.book);
  final VerifiedFriendBook book;
  String? active;
  final identities = <String, String>{};
  final _identityAt = <String, DateTime>{};
  final _seen = <String, DateTime>{};
  final _positions = <String, NearbyPosition>{};
  CampusFix? ownFix;
  NearbyConfig get config {
    final settings = book.settings;
    if (settings == null) {
      throw StateError('Open Friends once to prepare Bluetooth.');
    }
    return NearbyConfig(settings);
  }

  void identify(String peerToken, String code) {
    if (active != null &&
        code != book.selfCode &&
        (identities.containsKey(peerToken) ||
            identities.length < config.maxPeers * 2)) {
      identities[peerToken] = code;
      _identityAt[peerToken] = DateTime.now();
    }
  }

  bool fresh(String token) =>
      active != null &&
      _seen[token]?.add(config.encounter).isAfter(DateTime.now()) == true;
  DateTime? deadline(String token) => _seen[token]?.add(config.encounter);
  void _observe(String token) {
    if (active == null || token == active || !identities.containsKey(token)) {
      return;
    }
    if (_seen.containsKey(token) || _seen.length < config.maxPeers) {
      _seen[token] = DateTime.now();
    }
  }

  @override
  Future<NearbySession> open(String requestId) async {
    if (!book.loaded || book.selfCode == null) {
      throw StateError('Open Friends once to prepare Bluetooth.');
    }
    final c = config;
    active = requestId;
    identities.clear();
    _identityAt.clear();
    _seen.clear();
    _positions.clear();
    return NearbySession(requestId, c);
  }

  @override
  Future<void> heartbeat(String session, CampusFix? fix) async {
    if (active != session) throw StateError('Bluetooth session closed.');
    ownFix = fix;
  }

  @override
  Future<String?> challenge(String session, String peer) async {
    if (active != session) return null;
    _observe(peer);
    return active; // receiver sees the initiator's fresh discovery session
  }

  @override
  Future<bool> confirm(String session, String peer) async {
    if (active != session) return false;
    _observe(peer);
    return fresh(peer);
  }

  @override
  Future<NearbySnapshot> read(String session) async {
    if (active != session) throw StateError('Bluetooth session closed.');
    _seen.removeWhere(
      (_, at) => !at.add(config.encounter).isAfter(DateTime.now()),
    );
    identities.removeWhere(
      (token, _) =>
          !_seen.containsKey(token) &&
          _identityAt[token]?.add(config.encounter).isAfter(DateTime.now()) !=
              true,
    );
    _identityAt.removeWhere((token, _) => !identities.containsKey(token));
    return NearbySnapshot([
      for (final e in _seen.entries)
        NearbyPeer(
          e.key,
          book.byCode(identities[e.key]!)?.label ??
              'Player ${e.key.substring(0, 4)}',
          e.value.add(config.encounter),
          book.byCode(identities[e.key]!) == null ? null : _positions[e.key],
          friendship: book.byCode(identities[e.key]!) == null
              ? Friendship.none
              : Friendship.accepted,
          relationshipId: book.byCode(identities[e.key]!)?.id,
          identityCode: identities[e.key],
        ),
    ], config);
  }

  void position(String peer, NearbyPosition? position) {
    if (position == null) {
      _positions.remove(peer);
    } else if (fresh(peer) && book.byCode(identities[peer] ?? '') != null) {
      _positions[peer] = position;
    }
  }

  Map<String, dynamic>? encodePosition() {
    final fix = ownFix;
    if (fix == null || !config.accepts(fix, DateTime.now())) return null;
    return {
      'lat': fix.point.latitude,
      'lng': fix.point.longitude,
      'accuracy': fix.accuracy,
      'at': fix.timestamp.toUtc().toIso8601String(),
    };
  }

  void receivePosition(String peer, Map<String, dynamic>? row) {
    if (row == null) {
      position(peer, null);
      return;
    }
    try {
      final fix = CampusFix(
        CampusPoint(
          (row['lng'] as num).toDouble(),
          (row['lat'] as num).toDouble(),
        ),
        (row['accuracy'] as num).toDouble(),
        DateTime.parse(row['at'] as String),
      );
      if (config.accepts(fix, DateTime.now())) {
        position(
          peer,
          NearbyPosition(
            fix.point.latitude,
            fix.point.longitude,
            fix.timestamp.add(config.fixAge),
          ),
        );
      }
    } catch (_) {
      /* Malformed data never becomes a map marker. */
    }
  }

  @override
  Future<void> close(String session) async {
    if (active != session) return;
    active = null;
    ownFix = null;
    _seen.clear();
    identities.clear();
    _identityAt.clear();
    _positions.clear();
  }
}
