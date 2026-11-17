import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../map/campus_fix.dart';
import 'quiz_models.dart';

String quizRequestId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = bytes[6] & 15 | 64;
  bytes[8] = bytes[8] & 63 | 128;
  final h = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

abstract interface class QuizRepository {
  Future<List<QuizLocation>> catalog();
  Future<QuizAttempt> begin(String location, String request, CampusFix fix);
  Future<QuizAttempt> answer(
    String attempt,
    String command,
    bool selected,
    CampusFix fix,
  );
}

class SupabaseQuizRepository implements QuizRepository {
  SupabaseQuizRepository(this.client) : userId = client.auth.currentUser!.id;
  final SupabaseClient client;
  final String userId;
  Future<dynamic> _rpc(String name, [Map<String, dynamic>? params]) async {
    void check() {
      if (client.auth.currentUser?.id != userId) {
        throw StateError('Account changed.');
      }
    }

    check();
    final value = await client
        .rpc(name, params: params)
        .timeout(const Duration(seconds: 20));
    check();
    return value;
  }

  Map<String, dynamic> _fix(CampusFix f) => {
    'latitude': f.point.latitude,
    'longitude': f.point.longitude,
    'accuracy_meters': f.accuracy,
    'fix_at': f.timestamp.toUtc().toIso8601String(),
  };
  @override
  Future<List<QuizLocation>> catalog() async =>
      ((await _rpc('sp_quiz_catalog')) as List)
          .map(
            (r) => QuizLocation.fromJson(Map<String, dynamic>.from(r as Map)),
          )
          .toList();
  @override
  Future<QuizAttempt> begin(
    String location,
    String request,
    CampusFix fix,
  ) async => QuizAttempt.fromJson(
    Map<String, dynamic>.from(
      await _rpc('sp_quiz_begin', {
            'location_id': location,
            'request_id': request,
            ..._fix(fix),
          })
          as Map,
    ),
  );
  @override
  Future<QuizAttempt> answer(
    String attempt,
    String command,
    bool selected,
    CampusFix fix,
  ) async => QuizAttempt.fromJson(
    Map<String, dynamic>.from(
      await _rpc('sp_quiz_answer', {
            'attempt_id': attempt,
            'command_id': command,
            'selected': selected,
            ..._fix(fix),
          })
          as Map,
    ),
  );
}

/// Bounded RPC polling works with SP's private schema without exposing tables.
/// Reuses GOTest's load/observe boundary; no local production score fallback.
class QuizCatalog extends ChangeNotifier {
  QuizCatalog(this.repository);
  final QuizRepository repository;
  List<QuizLocation> points = const [];
  bool loaded = false, busy = false, _disposed = false, _active = true;
  String? error;
  Timer? _timer;
  QuizLocation? find(String id) {
    for (final point in points) {
      if (point.id == id) return point;
    }
    return null;
  }

  void apply(QuizLocation location) {
    if (_disposed) return;
    final previous = find(location.id);
    if (previous != null && previous.revision > location.revision) return;
    points = List.unmodifiable([
      for (final p in points)
        if (p.id != location.id) p,
      if (location.enabled) location,
    ]);
    notifyListeners();
  }

  void setActive(bool value) {
    _active = value;
    _timer?.cancel();
    if (value) unawaited(load());
  }

  Future<void> load() async {
    if (_disposed || busy || !_active) return;
    busy = true;
    try {
      final next = await repository.catalog();
      if (_disposed) return;
      if (next.map((p) => p.id).toSet().length != next.length) {
        throw const FormatException('Duplicate quiz locations.');
      }
      points = List.unmodifiable(
        next.where((p) => p.enabled).map((p) {
          final previous = find(p.id);
          return previous != null && previous.revision > p.revision
              ? previous
              : p;
        }),
      );
      loaded = true;
      error = null;
    } catch (_) {
      if (!_disposed) {
        error = 'Quizzes are unavailable. Check your connection and retry.';
      }
    } finally {
      busy = false;
      if (!_disposed) {
        notifyListeners();
        _timer?.cancel();
        if (_active) {
          _timer = Timer(const Duration(seconds: 5), () => unawaited(load()));
        }
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
