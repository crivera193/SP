import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

import 'map_lottie_spot.dart';

/// Animated Monstera plant.
class MonsteraLeaf extends StatelessWidget {
  const MonsteraLeaf({super.key});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        width: 90,
        height: 110,
        child: Lottie.asset(
          'assets/animations/plants/Monstera_leaf.json',
          fit: BoxFit.contain,
          repeat: true,
        ),
      ),
    );
  }
}

/// Interactive Monstera map marker.
class MonsteraSpot extends StatelessWidget {
  const MonsteraSpot({super.key, required this.position});

  final Offset position;

  @override
  Widget build(BuildContext context) {
    return MapLottieSpot(
      position: position,
      name: 'Monstera Plant',
      description: 'A large Monstera plant on campus.',
      width: 90,
      height: 110,
      anchorY: 110,
      child: const MonsteraLeaf(),
    );
  }
}
