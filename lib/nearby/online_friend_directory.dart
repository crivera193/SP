import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'verified_friend_book.dart';

/// Normal online account management, deliberately outside the Bluetooth stack.
/// Bluetooth never receives this object or a callback to any of its methods.
class OnlineFriendDirectory extends ChangeNotifier {
  OnlineFriendDirectory(this.client, this.book);
  final SupabaseClient client;
  final VerifiedFriendBook book;
  bool busy = false;
  bool _disposed = false;
  String? error;
  Future<void> refresh() => _action(() async {
    final row = await client
        .rpc('sp_friend_directory_read')
        .timeout(const Duration(seconds: 10));
    if (!_disposed) await book.replace(Map<String, dynamic>.from(row as Map));
  });
  Future<void> request(String code) => _action(() async {
    await client
        .rpc(
          'sp_friend_directory_request_code',
          params: {'friend_code': code.trim()},
        )
        .timeout(const Duration(seconds: 10));
    final row = await client
        .rpc('sp_friend_directory_read')
        .timeout(const Duration(seconds: 10));
    if (!_disposed) await book.replace(Map<String, dynamic>.from(row as Map));
  });
  Future<void> respond(String id, String action) => _action(() async {
    if (action == 'remove') await book.withdraw(id);
    await client
        .rpc(
          'sp_friend_directory_respond',
          params: {'relationship_id': id, 'action': action},
        )
        .timeout(const Duration(seconds: 10));
    final row = await client
        .rpc('sp_friend_directory_read')
        .timeout(const Duration(seconds: 10));
    if (!_disposed) await book.replace(Map<String, dynamic>.from(row as Map));
  });
  Future<void> _action(Future<void> Function() action) async {
    if (busy || _disposed) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await action();
    } catch (_) {
      error =
          'Friends could not refresh. Your previously verified Bluetooth friends are still available offline.';
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
