import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

import 'map_lottie_spot.dart';

/// Interactive Kitty Island Lottie game spots.
/// All three cats open the Kitty Island information modal.
class KittyIslandCats extends StatelessWidget {
  const KittyIslandCats({super.key, required this.positions});

  final List<Offset> positions;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        for (var i = 0; i < positions.length; i++)
          MapLottieSpot(
            position: positions[i],
            name: 'Kitty Island',
            description: 'Feed the campus cats for a gift.',
            width: 90,
            height: 65,
            anchorY: 59,
            child: _Cat(index: i),
          ),
      ],
    );
  }
}

/// Individual animated Kitty Island cat.
class _Cat extends StatefulWidget {
  const _Cat({required this.index});

  final int index;

  @override
  State<_Cat> createState() => _CatState();
}

class _CatState extends State<_Cat> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);

  bool _loaded = false;

  /// Start or stop the Lottie animation.
  void _play() {
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
    _play();
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 350),
      curve: Curves.easeOutBack,
      builder: (context, scale, child) {
        return Transform.scale(
          scale: scale,
          alignment: Alignment.bottomCenter,
          child: child,
        );
      },
      child: Lottie.asset(
        'assets/animations/kitty-island/cat-${const ['dark', 'orange', 'gray'][widget.index % 3]}.json',
        controller: _controller,
        fit: BoxFit.contain,
        onLoaded: (composition) {
          _controller.duration = composition.duration;
          _controller.value = widget.index / 3;
          _loaded = true;
          _play();
        },
        errorBuilder: (context, error, stackTrace) {
          return const SizedBox.shrink();
        },
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
