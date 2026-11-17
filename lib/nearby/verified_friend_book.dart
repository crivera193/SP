import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'friend_protocol.dart';
import 'nearby_models.dart';

class VerifiedFriend {
  VerifiedFriend(this.id, this.code, this.label, this.status, this.keyHex);
  final String id, code, label;
  final Friendship status;
  final String? keyHex;
}

/// The Bluetooth stack receives this data-only book, not a Supabase client or
/// callback capable of going online. Credentials are account/project scoped in
/// the existing private application sandbox, persist until a known friend change,
/// and never appear in logs, advertisements or public profile data.
class VerifiedFriendBook extends ChangeNotifier {
  VerifiedFriendBook(this.account);
  final String account;
  String? selfCode;
  DateTime? expiresAt;
  bool durable = false;
  Map<String, dynamic>? settings;
  List<VerifiedFriend> friends = const [];
  bool loaded = false;
  bool _disposed = false;
  Map<String, dynamic>? _saved;
  bool get valid => durable || expiresAt?.isAfter(DateTime.now()) == true;
  String get _storageKey => 'sp_bsvcnndqvjizxgnxhxkd_friends_v2_$account';
  VerifiedFriend? byCode(String code) {
    if (!valid) return null;
    for (final f in friends) {
      if (f.code == code &&
          f.status == Friendship.accepted &&
          f.keyHex != null) {
        return f;
      }
    }
    return null;
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw != null) {
      try {
        _decode(Map<String, dynamic>.from(jsonDecode(raw)));
      } catch (_) {
        /* A corrupt/expired cache never grants friend access. */
      }
    }
    loaded = true;
    if (!_disposed) notifyListeners();
  }

  void _decode(Map<String, dynamic> row) {
    if (row['account'] != account) {
      throw const FormatException('Account mismatch');
    }
    final nextSettings = Map<String, dynamic>.from(row['settings'] as Map);
    NearbyConfig(nextSettings);
    final persistent = row['trust_policy'] == 'until_friend_change';
    final until = row['valid_until'] == null
        ? null
        : DateTime.parse(row['valid_until'] as String);
    if (!persistent && until == null) {
      throw const FormatException('Friend permission missing');
    }
    final code = row['self_code'] as String;
    if (!RegExp(r'^[0-9a-f-]{36}$').hasMatch(code)) {
      throw const FormatException('Identity missing');
    }
    final entries = <VerifiedFriend>[];
    for (final item in row['entries'] as List) {
      final f = Map<String, dynamic>.from(item as Map);
      final status = friendshipFrom(f['status']);
      final key = f['key_hex'] as String?;
      if (status == Friendship.accepted &&
          (key == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(key))) {
        throw const FormatException('Friend credential missing');
      }
      entries.add(
        VerifiedFriend(
          f['id'] as String,
          f['code'] as String,
          f['label'] as String,
          status,
          key,
        ),
      );
    }
    selfCode = code;
    settings = nextSettings;
    expiresAt = until;
    durable = persistent;
    friends = entries;
    _saved = row;
  }

  Future<void> replace(Map<String, dynamic> row) async {
    final scoped = {...row, 'account': account};
    _decode(scoped);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(scoped));
    loaded = true;
    if (!_disposed) notifyListeners();
  }

  Future<void> withdraw(String relationship) async {
    friends = friends.where((f) => f.id != relationship).toList();
    if (!_disposed) notifyListeners();
    final saved = _saved;
    if (saved == null) return;
    final next = {
      ...saved,
      'entries': [
        for (final f in saved['entries'] as List)
          if ((f as Map)['id'] != relationship) f,
      ],
    };
    _saved = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(next));
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
