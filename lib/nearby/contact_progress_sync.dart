import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'contact_log.dart';

/// Ordinary online account work. Never passed to the BLE radio/controller.
class ContactProgressSync with WidgetsBindingObserver {
  ContactProgressSync(this.client, this.log) {
    WidgetsBinding.instance.addObserver(this);
    _active =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  }
  final SupabaseClient client;
  final ContactLog log;
  Timer? _timer;
  bool _active = true, _busy = false, _disposed = false;
  bool get _current =>
      !_disposed && _active && client.auth.currentUser?.id == log.account;
  Future<void> start() async {
    try {
      await log.load();
      if (_current) await sync();
    } catch (_) {
      if (_current) log.syncFailed();
    }
  }

  Future<void> sync() async {
    if (!_current || _busy || !log.loaded) return;
    _busy = true;
    try {
      do {
        await log.save();
        if (!_current) return;
        final batch = log.pending.take(50).toList();
        final response = Map<String, dynamic>.from(
          await client
                  .rpc(
                    'sp_contacts_sync',
                    params: {
                      'account_id': log.account,
                      'events': batch.map((r) => r.toJson()).toList(),
                    },
                  )
                  .timeout(const Duration(seconds: 10))
              as Map,
        );
        if (!_current) return;
        final ids = (response['accepted'] as List).cast<String>().toSet();
        if (ids.length != batch.length ||
            !ids.containsAll(batch.map((r) => r.id))) {
          throw const FormatException('Incomplete contact receipt.');
        }
        await log.acknowledge(
          ids,
          ContactProgress.fromJson(
            Map<String, dynamic>.from(response['progress'] as Map),
          ),
        );
      } while (_current && log.pending.length >= 50);
    } catch (_) {
      if (_current) log.syncFailed();
    } finally {
      _busy = false;
      _timer?.cancel();
      if (_current) {
        _timer = Timer(const Duration(seconds: 30), () => unawaited(sync()));
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    if (_active) {
      unawaited(sync());
    } else {
      _timer?.cancel();
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }
}
