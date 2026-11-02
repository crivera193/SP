import 'campus_geography.dart';

/// Raw provider evidence; never constructed from the cosmetic cowboy position.
class CampusFix {
  const CampusFix(this.point, this.accuracy, this.timestamp);
  final CampusPoint point;
  final double accuracy;
  final DateTime timestamp;
}
