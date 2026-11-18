import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'nearby_models.dart';
import 'friend_protocol.dart';

/// Local BLE observations only. This class has no network client or GPS input.
class ContactRecord {
  ContactRecord({
    required this.id,
    required this.ownSession,
    required this.peerSession,
    required this.peerCode,
    required this.contactId,
    required this.startedAt,
    required this.endedAt,
    required this.durationMs,
  });
  factory ContactRecord.fromJson(Map<String, dynamic> j) => ContactRecord(
    id: j['id'] as String,
    ownSession: j['own_session'] as String,
    peerSession: j['peer_session'] as String,
    peerCode: j['peer_code'] as String?,
    contactId: j['contact_id'] as String?,
    startedAt: DateTime.parse(j['started_at'] as String),
    endedAt: DateTime.parse(j['ended_at'] as String),
    durationMs: j['duration_ms'] as int,
  );
  final String id, ownSession, peerSession;
  final String? peerCode, contactId;
  final DateTime startedAt, endedAt;
  final int durationMs;
  Map<String, dynamic> toJson() => {
    'id': id,
    'own_session': ownSession,
    'peer_session': peerSession,
    'peer_code': peerCode,
    'contact_id': contactId,
    'started_at': startedAt.toUtc().toIso8601String(),
    'ended_at': endedAt.toUtc().toIso8601String(),
    'duration_ms': durationMs,
  };
}

class ContactProgress {
  ContactProgress.fromJson(Map<String, dynamic> j)
    : level = j['level'] as int,
      friendSeconds = j['friend_seconds'] as int,
      secondsPerLevel = j['seconds_per_level'] as int,
      quizPoints = j['quiz_points'] as int,
      secondsIntoLevel = j['seconds_into_level'] as int {
    if (secondsPerLevel <= 0 ||
        quizPoints < 1 ||
        friendSeconds < 0 ||
        level != 1 + friendSeconds ~/ secondsPerLevel ||
        secondsIntoLevel != friendSeconds % secondsPerLevel) {
      throw const FormatException('Invalid contact progress.');
    }
  }
  final int level, friendSeconds, secondsPerLevel, secondsIntoLevel, quizPoints;
  Map<String, dynamic> toJson() => {
    'level': level,
    'quiz_points': quizPoints,
    'friend_seconds': friendSeconds,
    'seconds_per_level': secondsPerLevel,
    'seconds_into_level': secondsIntoLevel,
  };
}

class _ContactSample {
  _ContactSample(
    this.session,
    this.contact,
    this.at,
    this.elapsed,
    this.seenAt,
  );
  final String session;
  final String? contact;
  final DateTime at, seenAt;
  final Duration elapsed;
}

class ContactLog extends ChangeNotifier {
  ContactLog(
    this.account, {
    DateTime Function()? now,
    Duration Function()? elapsed,
  }) : _now = now ?? DateTime.now {
    final watch = Stopwatch()..start();
    _elapsed = elapsed ?? (() => watch.elapsed);
  }
  final String account;
  final DateTime Function() _now;
  late final Duration Function() _elapsed;
  String get _key => 'sp_bsvcnndqvjizxgnxhxkd_contacts_v1_$account';
  final _pending = <ContactRecord>[];
  final _samples = <String, _ContactSample>{};
  Future<void> _saved = Future.value();
  bool loaded = false, _disposed = false;
  String? error;
  ContactProgress? progress;
  List<ContactRecord> get pending => List.unmodifiable(_pending);
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    if (loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      final j = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      if (j['account'] != account) {
        throw const FormatException('Contact account mismatch.');
      }
      _pending.addAll(
        (j['pending'] as List).map(
          (v) => ContactRecord.fromJson(Map<String, dynamic>.from(v as Map)),
        ),
      );
      if (j['progress'] case final Map value) {
        progress = ContactProgress.fromJson(Map<String, dynamic>.from(value));
      }
    }
    loaded = true;
    _notify();
  }

  /// A cached scan result cannot advance time. Each sample needs a newer actual
  /// GATT receipt, saved verified-friend credentials, and bounded monotonic elapsed time.
  void sample(
    String session,
    List<NearbyPeer> peers,
    Duration encounter,
    Map<String, String> eligibleContacts,
  ) {
    if (!loaded || _disposed) return;
    final now = _now().toUtc(), elapsed = _elapsed();
    final present = <String>{};
    var changed = false;
    for (final peer in peers) {
      if (!peer.expiresAt.isAfter(now)) continue;
      final seen = peer.expiresAt.subtract(encounter).toUtc();
      if (seen.isAfter(now)) continue;
      present.add(peer.id);
      final contact = peer.friendship == Friendship.accepted
          ? eligibleContacts[peer.id]
          : null;
      final previous = _samples[peer.id];
      if (previous != null &&
          previous.session == session &&
          previous.contact == contact &&
          !seen.isAfter(previous.seenAt)) {
        continue;
      }
      var duration = 0;
      if (previous != null &&
          previous.session == session &&
          previous.contact == contact &&
          contact != null &&
          seen.isAfter(previous.seenAt)) {
        final delta = (elapsed - previous.elapsed).inMilliseconds;
        final wall = now.difference(previous.at).inMilliseconds;
        if (delta > 0 &&
            delta <= encounter.inMilliseconds &&
            seen.difference(previous.seenAt) <= encounter &&
            (wall - delta).abs() <= 1000) {
          duration = delta;
        }
      }
      _samples[peer.id] = _ContactSample(session, contact, now, elapsed, seen);
      _pending.add(
        ContactRecord(
          id: NearbyProtocol.randomId(),
          ownSession: session,
          peerSession: peer.id,
          peerCode: peer.identityCode,
          contactId: contact,
          startedAt: now.subtract(Duration(milliseconds: duration)),
          endedAt: now,
          durationMs: duration,
        ),
      );
      changed = true;
    }
    _samples.removeWhere((id, _) => !present.contains(id));
    if (changed) {
      unawaited(save().catchError((Object _) {}));
      _notify();
    }
  }

  void pause() => _samples.clear();
  Future<void> save() {
    final encoded = jsonEncode({
      'account': account,
      'pending': _pending.map((r) => r.toJson()).toList(),
      'progress': progress?.toJson(),
    });
    _saved = _saved.catchError((Object _) {}).then((_) async {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(_key, encoded)) {
        throw StateError('Contact log could not be saved.');
      }
    });
    return _saved;
  }

  Future<void> acknowledge(Set<String> ids, ContactProgress confirmed) async {
    _pending.removeWhere((r) => ids.contains(r.id));
    progress = confirmed;
    error = null;
    await save();
    _notify();
  }

  void syncFailed() {
    error = 'Level progress will sync when connected.';
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    pause();
    super.dispose();
  }
}
