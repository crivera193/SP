import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

/// Resting marker for a campus spot that has not been revealed by GPS.
/// Uses the same screen anchor as the revealed landmark.
class DiamondSpot extends StatelessWidget {
  const DiamondSpot({
    super.key,
    required this.position,
    required this.width,
    required this.height,
    required this.anchorY,
  });

  final Offset position;
  final double width;
  final double height;
  final double anchorY;

  @override
  Widget build(BuildContext context) => Positioned(
    left: position.dx - width / 2,
    top: position.dy - anchorY,
    width: width,
    height: height,
    child: IgnorePointer(
      child: RepaintBoundary(
        child: Lottie.asset(
          'assets/animations/markers/diamond_resting.json',
          fit: BoxFit.contain,
          repeat: true,
        ),
      ),
    ),
  );
}
