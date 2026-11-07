import 'package:flutter/material.dart';

class MapLottieSpot extends StatelessWidget {
  const MapLottieSpot({
    super.key,
    required this.position,
    required this.name,
    required this.child,
    required this.width,
    required this.height,
    required this.anchorY,
    this.description = 'Campus Game Spot',
    this.onTap,
  });

  final Offset position;
  final String name;
  final String description;
  final Widget child;
  final double width;
  final double height;
  final double anchorY;
  final VoidCallback? onTap;

  void _openCard(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(name, style: Theme.of(sheetContext).textTheme.headlineSmall),
              const SizedBox(height: 12),
              Text(description, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              const Text(
                'Game Spot',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Mini-game and team ownership '
                'coming soon.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: position.dx - width / 2,
      top: position.dy - anchorY,
      width: width,
      height: height,
      child: Semantics(
        label: '$name, open game spot',
        button: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap ?? () => _openCard(context),
          child: RepaintBoundary(child: child),
        ),
      ),
    );
  }
}
