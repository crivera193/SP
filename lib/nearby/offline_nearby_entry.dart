import 'dart:async';
import 'package:flutter/material.dart';
import 'ble_nearby_radio.dart';
import 'nearby_controller.dart';
import 'nearby_widgets.dart';
import 'offline_nearby_repository.dart';
import 'verified_friend_book.dart';
import 'contact_log.dart';
import 'hat_tip.dart';

/// Opens only Bluetooth from an account's saved credentials. It has no online
/// client and cannot unlock the normal team/game routes when their checks fail.
class OfflineNearbyEntry extends StatefulWidget {
  const OfflineNearbyEntry({super.key, required this.account});
  final String account;
  @override
  State<OfflineNearbyEntry> createState() => _OfflineNearbyEntryState();
}

class _OfflineNearbyEntryState extends State<OfflineNearbyEntry> {
  late final VerifiedFriendBook _book;
  late final NearbyController _nearby;
  late final ContactLog _contacts;
  late final HatTipTeams _teams;
  bool _loaded = false;
  @override
  void initState() {
    super.initState();
    _book = VerifiedFriendBook(widget.account);
    _contacts = ContactLog(widget.account);
    _teams = HatTipTeams(widget.account);
    final local = OfflineNearbyRepository(_book);
    final radio = BleNearbyRadio(
      identity: () => _book.selfCode,
      onIdentity: local.identify,
      teams: _teams,
      onChanged: () => _nearby.hatStateChanged(),
    );
    _nearby = NearbyController(local, radio, contacts: _contacts);
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await _book.load();
      await _contacts.load();
      await _teams.load();
    } catch (_) {
      // An unavailable private cache cannot authorize a friend session.
    }
    if (mounted) setState(() => _loaded = true);
  }

  @override
  void dispose() {
    _nearby.dispose();
    _contacts.dispose();
    _book.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    if (_book.selfCode == null || _book.settings == null) {
      return const Padding(
        padding: EdgeInsets.all(8),
        child: Text('Open the app online once to prepare Nearby.'),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: NearbyButton(controller: _nearby),
    );
  }
}
