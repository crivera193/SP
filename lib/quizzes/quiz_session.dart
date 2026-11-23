import 'package:flutter/foundation.dart';
import '../map/campus_fix.dart';
import 'quiz_models.dart';
import 'quiz_repository.dart';

/// No optimistic credit. Retain one command/choice across an uncertain response.
class QuizSession extends ChangeNotifier {
  QuizSession(
    this.catalog,
    this.locationId,
    this.currentFix,
    this.unavailableReason,
  );
  final QuizCatalog catalog;
  final String locationId;
  final CampusFix? Function() currentFix;
  final String? Function() unavailableReason;
  final String _request = quizRequestId();
  final _clock = Stopwatch();
  QuizAttempt? attempt;
  bool busy = false, _disposed = false;
  String? error, _command;
  bool? _selected;
  CampusFix? _pendingFix;
  bool get retryPending => _command != null;
  QuizLocation? get location => catalog.find(locationId);
  int get cooldownSeconds {
    final a = attempt;
    if (a == null || a.retryAt == null) return 0;
    return ((a.retryAt!.difference(a.serverNow).inMilliseconds -
                _clock.elapsedMilliseconds) /
            1000)
        .ceil()
        .clamp(0, 86400);
  }

  void _accept(QuizAttempt next) {
    if (_disposed) return;
    attempt = next;
    _clock
      ..reset()
      ..start();
    catalog.apply(next.location);
    error = null;
  }

  Future<void> load() async {
    if (busy || _disposed) return;
    if (retryPending) {
      await retry();
      return;
    }
    final reason = unavailableReason(), fix = currentFix();
    if (reason != null || fix == null) {
      error = reason ?? 'A fresh GPS position is required.';
      notifyListeners();
      return;
    }
    busy = true;
    notifyListeners();
    try {
      final repository = catalog.repository;
      var next = await repository.begin(locationId, _request, fix);
      if (next.generating && repository is SupabaseQuizRepository) {
        next = await repository.waitUntilReady(next.id);
      }
      if (next.status == 'generation_failed') {
        error = 'Could not generate the quiz. Try again.';
        return;
      }
      _accept(next);
    } catch (_) {
      if (!_disposed) {
        error = 'Could not load the quiz. Check your connection and retry.';
      }
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> answer(bool selected) async {
    if (busy || _disposed || attempt?.active != true || retryPending) return;
    final reason = unavailableReason(), fix = currentFix();
    if (reason != null || fix == null) {
      error = reason ?? 'A fresh GPS position is required.';
      notifyListeners();
      return;
    }
    _command = quizRequestId();
    _selected = selected;
    _pendingFix = fix;
    await retry();
  }

  Future<void> retry() async {
    if (busy || _disposed || _command == null || attempt == null) return;
    busy = true;
    notifyListeners();
    try {
      final next = await catalog.repository.answer(
        attempt!.id,
        _command!,
        _selected!,
        currentFix() ?? _pendingFix!,
      );
      if (_disposed) return;
      _accept(next);
      _command = null;
      _selected = null;
      _pendingFix = null;
    } catch (_) {
      if (!_disposed) {
        error =
            'The answer is not confirmed. Retry the same answer to check its saved result.';
      }
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _clock.stop();
    super.dispose();
  }
}
