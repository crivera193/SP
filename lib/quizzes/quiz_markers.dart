import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'quiz_models.dart';

/// Animation vocabulary is bundled artwork; locations, offsets and owners are data.
class QuizMarkers extends StatelessWidget {
  const QuizMarkers({
    super.key,
    required this.locations,
    required this.positions,
    required this.revealed,
    required this.canOpen,
    required this.onOpen,
  });
  final List<QuizLocation> locations;
  final Map<String, Offset> positions;
  final Set<String> revealed;
  final bool Function(QuizLocation) canOpen;
  final void Function(QuizLocation) onOpen;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) => Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        for (final location in locations)
          if (!revealed.contains(location.id)) ...[
            if (positions[location.id] case final Offset p)
              _marker(location, p, -1, bounds),
          ] else ...[
            for (var i = 0; i < location.artOffsets.length; i++)
              if (positions['${location.id}#$i'] case final Offset p)
                _marker(location, p, i, bounds),
          ],
      ],
    ),
  );
  Widget _marker(QuizLocation l, Offset p, int index, BoxConstraints bounds) {
    final diamond = index < 0;
    final enabled = !diamond && canOpen(l);
    final (width, height, anchorY) = diamond
        ? (90.0, 90.0, 75.0)
        : switch (l.animation) {
            'horse' => (120.0, 120.0, 75.0),
            'plant' => (90.0, 110.0, 110.0),
            _ => (90.0, 65.0, 59.0),
          };
    if (p.dx < -width ||
        p.dy < -height ||
        p.dx > bounds.maxWidth + width ||
        p.dy > bounds.maxHeight + height) {
      return const SizedBox.shrink();
    }
    final asset = diamond
        ? 'assets/animations/markers/diamond_resting.json'
        : switch (l.animation) {
            'horse' => 'assets/animations/animals/stallion.json',
            'plant' => 'assets/animations/plants/Monstera_leaf.json',
            _ =>
              'assets/animations/kitty-island/cat-${const ['dark', 'orange', 'gray'][index % 3]}.json',
          };
    return Positioned(
      key: ValueKey('${l.id}:${diamond ? 'diamond' : index}'),
      left: p.dx - width / 2 + (l.animation == 'horse' && !diamond ? 10 : 0),
      top: p.dy - anchorY,
      width: width,
      height: height,
      child: Semantics(
        label:
            '${l.name}, ${l.owner?.displayName ?? 'unclaimed'}, ${diamond ? 'outside proximity' : 'nearby'}${enabled ? '. Open quiz' : ''}',
        button: true,
        enabled: enabled,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? () => onOpen(l) : null,
          child: RepaintBoundary(
            child: TeamLottie(
              key: ValueKey(asset),
              asset: asset,
              color: l.owner?.color ?? (diamond ? Colors.grey : null),
            ),
          ),
        ),
      ),
    );
  }
}

/// Change fill hues without flattening eye/outline details or source shading.
class TeamLottie extends StatefulWidget {
  const TeamLottie({super.key, required this.asset, this.color});
  final String asset;
  final Color? color;
  @override
  State<TeamLottie> createState() => _TeamLottieState();
}

class _TeamLottieState extends State<TeamLottie>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this);
  bool _loaded = false;
  void _sync() {
    if (!_loaded) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
      _controller.value = 0;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  Color _tint(Color? start, Color? end, double progress) {
    final source = Color.lerp(start, end, progress) ?? widget.color!;
    final original = HSLColor.fromColor(source),
        target = HSLColor.fromColor(widget.color!);
    if (original.lightness < .04 || original.lightness > .96) return source;
    return target
        .withLightness(
          (original.lightness * .65 + target.lightness * .35).clamp(.08, .94),
        )
        .toColor()
        .withValues(alpha: source.a);
  }

  @override
  Widget build(BuildContext context) => Lottie.asset(
    widget.asset,
    controller: _controller,
    fit: BoxFit.contain,
    delegates: widget.color == null
        ? null
        : LottieDelegates(
            values: [
              ValueDelegate.color(
                const ['**'],
                callback: (frame) => _tint(
                  frame.startValue,
                  frame.endValue,
                  frame.interpolatedKeyframeProgress,
                ),
              ),
              ValueDelegate.strokeColor(
                const ['**'],
                callback: (frame) => _tint(
                  frame.startValue,
                  frame.endValue,
                  frame.interpolatedKeyframeProgress,
                ),
              ),
            ],
          ),
    onLoaded: (composition) {
      _controller.duration = composition.duration;
      _loaded = true;
      _sync();
    },
    errorBuilder: (context, error, stack) => const Center(
      child: Icon(
        Icons.error_outline,
        semanticLabel: 'Marker animation unavailable',
      ),
    ),
  );
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
