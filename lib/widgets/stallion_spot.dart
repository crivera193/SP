import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

import 'map_lottie_spot.dart';

/// Animated and interactive Stallion map marker.
class StallionSpot extends StatelessWidget {
  const StallionSpot({super.key, required this.position});

  final Offset position;

  @override
  Widget build(BuildContext context) {
    return MapLottieSpot(
      // Keep the Stallion centered in its circular lawn.
      position: Offset(position.dx + 10, position.dy),
      name: 'Bronco Point',
      description: 'Bucky the Bronco!',
      width: 120,
      height: 120,
      anchorY: 75,
      child: Lottie.asset(
        'assets/animations/animals/stallion.json',
        fit: BoxFit.contain,
        repeat: true,
      ),
    );
  }
}
