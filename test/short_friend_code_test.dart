import 'package:campus_app/nearby/friend_directory_widgets.dart';
import 'package:campus_app/nearby/online_friend_directory.dart';
import 'package:campus_app/nearby/verified_friend_book.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'offline_bluetooth_test.dart' as fixtures;

void main() {
  testWidgets(
    'Friends shows and copies a short code while preserving BLE identity',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      const identity = 'aa50621e-2540-4846-90f4-c8c36e1d3905';
      final book = VerifiedFriendBook('test-account');
      await book.replace({...fixtures.snapshot(true), 'self_code': identity});
      final client = (await tester.runAsync(
        () async => SupabaseClient('https://example.invalid', 'test-key'),
      ))!;
      final directory = OnlineFriendDirectory(client, book);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: FriendDirectoryPanel(directory: directory)),
        ),
      );
      expect(find.text('AA50-621E'), findsOneWidget);
      expect(find.text(identity), findsNothing);
      await tester.tap(find.byTooltip('Copy your friend code'));
      await tester.pump();
      expect(copied, 'AA50-621E');
      expect(book.selfCode, identity);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      directory.dispose();
      book.dispose();
      await tester.runAsync(client.dispose);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    },
  );
}
