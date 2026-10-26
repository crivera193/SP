
import 'dart:math' as math;
import 'package:flutter/material.dart';

/// UTRGV-GO login and registration theme.

// Primary dark navy blue.
const journalInk = Color(0xFF061E4A);

// Cream background.
const journalPaper = Color(0xFFF5F1E3);

// Orange accent.
const journalOrange = Color(0xFFE85C08);

/// Typography used by authentication screens.
TextStyle journalType(
  double size, {
  Color color = journalInk,
}) {
  return TextStyle(
    fontFamily: 'DMSerifDisplay',
    fontSize: size,
    height: 1.05,
    color: color,
  );
}

/// Decorative paper background for login
/// and registration screens.
class JournalPaper extends StatelessWidget {
  const JournalPaper({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: const _PaperPainter(),
      child: child,
    );
  }
}

/// Draws the cream background, subtle grid,
/// and small decorative paper flecks.
class _PaperPainter extends CustomPainter {
  const _PaperPainter();

  @override
  void paint(Canvas canvas, Size size) {
    // Cream background.
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = journalPaper,
    );

    // Very subtle grid.
    final grid = Paint()
      ..color = journalInk.withValues(alpha: 0.045)
      ..strokeWidth = 0.5;

    const gridSpacing = 18.0;

    for (
      double x = 0;
      x < size.width;
      x += gridSpacing
    ) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        grid,
      );
    }

    for (
      double y = 0;
      y < size.height;
      y += gridSpacing
    ) {
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        grid,
      );
    }

    // Decorative paper texture.
    final fleck = Paint()
      ..color = journalInk.withValues(alpha: 0.035);

    final random = math.Random(17);

    final count =
        (size.width * size.height / 150).floor();

    for (int i = 0; i < count; i++) {
      canvas.drawCircle(
        Offset(
          random.nextDouble() * size.width,
          random.nextDouble() * size.height,
        ),
        0.45,
        fleck,
      );
    }
  }

  @override
  bool shouldRepaint(
    covariant _PaperPainter oldDelegate,
  ) {
    return false;
  }
}
