import 'dart:convert';
import 'dart:io';
import 'package:campus_app/nearby/contact_log.dart';
import 'package:campus_app/nearby/contact_progress_sync.dart';
import 'package:campus_app/nearby/nearby_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'lost upload result retains the same persisted IDs; retry acknowledges only that batch',
    () async {
      SharedPreferences.setMockInitialValues({});
      final previous = HttpOverrides.current;
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      const account = '00000000-0000-4000-8000-000000000001';
      final expiry =
          DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
          1000;
      String part(Object value) =>
          base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
      final token =
          '${part({'alg': 'HS256', 'typ': 'JWT'})}.${part({'sub': account, 'exp': expiry, 'role': 'authenticated'})}.fixture';
      var requests = 0;
      final bodies = <Map<String, dynamic>>[], saved = <String>{};
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/auth/v1/token') {
          request.response.write(
            jsonEncode({
              'access_token': token,
              'token_type': 'bearer',
              'expires_in': 3600,
              'refresh_token': 'synthetic-refresh',
              'user': {
                'id': account,
                'email': 'fixture@utrgv.edu',
                'aud': 'authenticated',
                'created_at': DateTime.utc(2026).toIso8601String(),
                'app_metadata': {},
                'user_metadata': {},
              },
            }),
          );
        } else if (request.uri.path == '/rest/v1/rpc/sp_contacts_sync') {
          final body = Map<String, dynamic>.from(
            jsonDecode(await utf8.decoder.bind(request).join()) as Map,
          );
          bodies.add(body);
          requests++;
          final ids = (body['events'] as List)
              .map((r) => (r as Map)['id'] as String)
              .toList();
          saved.addAll(ids);
          if (requests == 1) {
            request.response.statusCode = 503;
            request.response.write(
              jsonEncode({'message': 'Simulated response loss after commit'}),
            );
          } else {
            request.response.write(
              jsonEncode({
                'accepted': ids,
                'progress': {
                  'level': 2,
                  'quiz_points': 1,
                  'friend_seconds': 600,
                  'seconds_per_level': 600,
                  'seconds_into_level': 0,
                },
              }),
            );
          }
        } else {
          request.response.statusCode = 404;
          request.response.write('{}');
        }
        await request.response.close();
      });
      final client = SupabaseClient(
        'http://127.0.0.1:${server.port}',
        'synthetic-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      final log = ContactLog(account);
      ContactProgressSync? sync;
      try {
        await client.auth.setSession('synthetic-refresh');
        await log.load();
        log.sample(
          '10000000-0000-4000-8000-000000000001',
          [
            NearbyPeer(
              '20000000-0000-4000-8000-000000000002',
              'fixture',
              DateTime.now().add(const Duration(seconds: 18)),
              null,
            ),
          ],
          const Duration(seconds: 18),
          {},
        );
        await log.save();
        final id = log.pending.single.id;
        sync = ContactProgressSync(client, log);
        await sync.start();
        expect(log.pending.single.id, id);
        expect(
          log.progress,
          isNull,
          reason: 'a failed response cannot grant optimistic levels',
        );
        final reopened = ContactLog(account);
        await reopened.load();
        expect(reopened.pending.single.id, id);
        reopened.dispose();
        await sync.sync();
        expect(requests, 2);
        expect(saved, {id});
        expect(
          bodies[0],
          bodies[1],
          reason:
              'transport retry must preserve the original contact receipt IDs and timestamps',
        );
        expect(
          bodies.singleWhere((b) => b == bodies.first)['account_id'],
          account,
        );
        expect(log.pending, isEmpty);
        expect(log.progress!.level, 2);
      } finally {
        sync?.dispose();
        log.dispose();
        await client.dispose();
        await server.close(force: true);
        HttpOverrides.global = previous;
      }
    },
  );
}
