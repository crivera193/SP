import 'package:campus_app/nearby/friend_directory_widgets.dart';
import 'package:campus_app/nearby/online_friend_directory.dart';
import 'package:campus_app/nearby/verified_friend_book.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'offline_bluetooth_test.dart' as fixtures;

void main() {
  testWidgets(
    'Friends is disabled and blank while saved BLE identity remains intact',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      const identity = 'aa50621e-2540-4846-90f4-c8c36e1d3905';
      final book = VerifiedFriendBook('test-account');
      await book.replace({...fixtures.snapshot(true), 'self_code': identity});
      final client = (await tester.runAsync(
        () async => SupabaseClient('https://example.invalid', 'test-key'),
      ))!;
      final directory = OnlineFriendDirectory(client, book);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                FriendDirectoryButton(directory: directory),
                FriendDirectoryPanel(directory: directory),
              ],
            ),
          ),
        ),
      );
      expect(find.text('Friends'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.tap(find.text('Friends'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Your friend code'), findsNothing);
      expect(find.text('Send friend request'), findsNothing);
      expect(find.text('AA50-621E'), findsNothing);
      expect(find.text(identity), findsNothing);
      expect(find.text('Friend B'), findsNothing);
      expect(book.selfCode, identity);
      expect(book.friends.single.label, 'Friend B');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      directory.dispose();
      book.dispose();
      await tester.runAsync(client.dispose);
    },
  );
}
