import 'package:campus_app/auth/student_email.dart';
import 'package:campus_app/auth/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('valid .edu addresses and deceptive domains', () {
    for (final email in [
      'student@utrgv.edu',
      ' Student@Campus.EDU ',
      'a@students.school.edu',
    ]) {
      expect(StudentEmail.isEligible(email), isTrue);
    }
    for (final email in [
      'a@gmail.com',
      'a@utrgv.edu.evil.com',
      'a@edu',
      'a@@school.edu',
      'a b@school.edu',
      'a@-school.edu',
      '',
    ]) {
      expect(StudentEmail.isEligible(email), isFalse);
    }
  });
  testWidgets(
    'signup validates passwords and acknowledges UI-only submission',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
      await tester.ensureVisible(find.text('Create an account'));
      await tester.tap(find.text('Create an account'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField).first,
        'student@school.edu',
      );
      await tester.enterText(find.byType(TextFormField).last, 'short');
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Create account'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
      await tester.pumpAndSettle();
      expect(find.text('Use at least 8 characters.'), findsOneWidget);
      await tester.enterText(
        find.byType(TextFormField).last,
        'example-password',
      );
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Create account'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Form valid. Authentication will be added in a later milestone.',
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText).last)
            .controller
            .text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
