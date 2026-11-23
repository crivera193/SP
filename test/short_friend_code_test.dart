import 'package:campus_app/nearby/nearby_models.dart';
import 'package:campus_app/nearby/verified_friend_book.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'offline_bluetooth_test.dart' as fixtures;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('saved BLE identity and friend credentials can still be read', () async {
    SharedPreferences.setMockInitialValues({});
    const identity = 'aa50621e-2540-4846-90f4-c8c36e1d3905';
    final book = VerifiedFriendBook('test-account');
    addTearDown(book.dispose);
    await book.replace({...fixtures.snapshot(true), 'self_code': identity});

    final saved = VerifiedFriendBook('test-account');
    addTearDown(saved.dispose);
    await saved.load();
    expect(saved.selfCode, identity);
    expect(NearbyProtocol.friendCode(saved.selfCode!), 'AA50-621E');
    expect(saved.friends.single.label, 'Friend B');
  });
}
