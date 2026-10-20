import 'package:campus_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('branded shell opens account route and returns', (tester) async {
    await tester.pumpWidget(const CampusApp());
    expect(find.text('UTRGV-GO'), findsOneWidget);
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    expect(find.text('School email'), findsOneWidget);
    Navigator.of(tester.element(find.text('School email'))).pop();
    await tester.pumpAndSettle();
    expect(find.text('UTRGV-GO'), findsOneWidget);
  });
}
