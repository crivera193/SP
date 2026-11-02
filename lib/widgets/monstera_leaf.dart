import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

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
