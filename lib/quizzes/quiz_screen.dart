import 'dart:async';
import 'package:flutter/material.dart';
import 'quiz_models.dart';
import 'quiz_repository.dart';
import 'quiz_session.dart';

class QuizScreen extends StatefulWidget {
  const QuizScreen({super.key, required this.session});
  final QuizSession session;
  @override
  State<QuizScreen> createState() => _QuizScreenState();
}

class _QuizScreenState extends State<QuizScreen> {
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    widget.session.addListener(_changed);
    widget.session.catalog.addListener(_changed);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _changed());
    unawaited(widget.session.load());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.session.removeListener(_changed);
    widget.session.catalog.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session, point = s.location, a = s.attempt;
    final reason = s.unavailableReason();
    return Scaffold(
      appBar: AppBar(title: Text(point?.name ?? 'Location quiz')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (s.busy) const LinearProgressIndicator(),
              if (point == null)
                const Text('This location has been disabled or removed.'),
              if (a != null) ...[
                Text(
                  a.prompt,
                  key: const ValueKey('quiz-question'),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 20),
                if (a.answered) ...[
                  Text(
                    a.correct == true
                        ? 'Correct! One point saved for your team.'
                        : 'Incorrect. No points awarded.',
                    key: const ValueKey('quiz-result'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    s.cooldownSeconds > 0
                        ? 'Next quiz in ${s.cooldownSeconds ~/ 60}:${(s.cooldownSeconds % 60).toString().padLeft(2, '0')}'
                        : 'You can open this location again for another quiz.',
                  ),
                ] else if (a.active) ...[
                  for (final choice in [true, false])
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: FilledButton(
                        onPressed: s.busy || s.retryPending || reason != null
                            ? null
                            : () => unawaited(s.answer(choice)),
                        key: ValueKey(choice ? 'quiz-true' : 'quiz-false'),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Text(choice ? 'A. True' : 'B. False'),
                        ),
                      ),
                    ),
                ] else
                  const Text(
                    'This quiz changed. Return to the map and reopen it.',
                  ),
              ],
              if (reason != null && a?.answered != true) Text(reason),
              if (s.error case final String error) ...[
                const SizedBox(height: 16),
                if (error != reason)
                  Text(error, key: const ValueKey('quiz-error')),
                OutlinedButton(
                  onPressed: s.busy ? null : () => unawaited(s.load()),
                  child: Text(
                    s.retryPending ? 'Retry saved answer' : 'Retry quiz',
                  ),
                ),
              ],
              if (point != null) ...[
                const SizedBox(height: 24),
                QuizScoreboard(location: point),
              ],
              const SizedBox(height: 24),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Return to map'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class QuizScoreboard extends StatelessWidget {
  const QuizScoreboard({super.key, required this.location});
  final QuizLocation location;
  @override
  Widget build(BuildContext context) {
    final highest = location.scores.fold<int>(
      0,
      (value, score) => score.correct > value ? score.correct : value,
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              location.owner == null
                  ? 'Unclaimed location'
                  : 'Leader: ${location.owner!.displayName}',
              key: const ValueKey('quiz-owner'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            for (final score in location.scores)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Semantics(
                  label: '${score.team.displayName}, ${score.correct} correct',
                  child: ExcludeSemantics(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(child: Text(score.team.displayName)),
                            const SizedBox(width: 12),
                            Text('${score.correct} correct'),
                          ],
                        ),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                            key: ValueKey('quiz-score-${score.team.id}'),
                            value: highest == 0 ? 0 : score.correct / highest,
                            minHeight: 12,
                            color: score.team.color,
                            backgroundColor: score.team.color.withValues(
                              alpha: .18,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class QuizCatalogNotice extends StatelessWidget {
  const QuizCatalogNotice({super.key, required this.catalog});
  final QuizCatalog catalog;
  @override
  Widget build(BuildContext context) => Material(
    borderRadius: BorderRadius.circular(12),
    color: Theme.of(context).colorScheme.surface,
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              catalog.error ??
                  (catalog.loaded
                      ? 'No quiz locations are available.'
                      : 'Loading quiz locations…'),
            ),
          ),
          if (catalog.error != null)
            TextButton(
              onPressed: () => unawaited(catalog.load()),
              child: const Text('Retry'),
            ),
        ],
      ),
    ),
  );
}
