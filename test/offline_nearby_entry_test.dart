import 'dart:io';
import 'package:campus_app/nearby/offline_nearby_entry.dart';
import 'package:campus_app/nearby/verified_friend_book.dart';
import 'package:campus_app/teams/team_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'offline_bluetooth_test.dart' as bluetooth;
import 'team_membership_test.dart' show MemoryTeams;
import 'team_fixtures.dart';

void main() {
  testWidgets(
    'offline Bluetooth opens without unlocking online team/game access',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final internet = bluetooth.NoInternet();
      HttpOverrides.global = internet;
      addTearDown(() => HttpOverrides.global = null);
      final book = VerifiedFriendBook('offline-account');
      await book.replace({
        ...bluetooth.snapshot(true),
        'trust_policy': 'until_friend_change',
        'valid_until': null,
      });
      book.dispose();
      final repository = MemoryTeams()
        ..saved = healthScience
        ..loadFails = true;
      await tester.pumpWidget(
        MaterialApp(
          home: TeamGate(
            repository: repository,
            onSignOut: () async {},
            offlineNearby: const OfflineNearbyEntry(account: 'offline-account'),
            child: const Text('PRIVATE GAME'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Retry team check'), findsOneWidget);
      expect(find.text('PRIVATE GAME'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('nearby-players')));
      await tester.pumpAndSettle();
      expect(find.text('Nearby players off'), findsOneWidget);
      expect(find.text('Turn on'), findsOneWidget);
      expect(find.text('Send'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(internet.attempts, 0);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      repository.loadFails = false;
      await tester.tap(find.text('Retry team check'));
      await tester.pumpAndSettle();
      expect(find.text('PRIVATE GAME'), findsOneWidget);
      expect(find.byKey(const ValueKey('nearby-players')), findsNothing);
      expect(internet.attempts, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a different account cannot reuse the offline entry credentials',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final book = VerifiedFriendBook('saved-account');
      await book.replace(bluetooth.snapshot(true));
      book.dispose();
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: OfflineNearbyEntry(account: 'different-account'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('nearby-players')), findsNothing);
      expect(
        find.text('Verify friends online once to prepare Bluetooth.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
