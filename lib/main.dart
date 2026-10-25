import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

import 'widgets/mapbox_configuration_notice.dart';
import 'auth/auth_gate.dart';
import 'config/app_configuration.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Mapbox.
  if (hasMapboxConfiguration) {
    MapboxOptions.setAccessToken(mapboxAccessToken);
  }

  // Initialize Supabase.
  String? startupError;

  if (AppConfiguration.hasBackend) {
    try {
      await Supabase.initialize(
        url: AppConfiguration.supabaseUrl,
        publishableKey: AppConfiguration.supabaseKey,
        authOptions: FlutterAuthClientOptions(
          localStorage: SharedPreferencesLocalStorage(
            persistSessionKey: 'campus_explorer_v1_session',
          ),
        ),
      );
    } catch (_) {
      startupError =
          'Unable to connect to the account service. '
          'Please restart and try again.';
    }
  }

  runApp(CampusApp(startupError: startupError));
}

class CampusApp extends StatelessWidget {
  const CampusApp({super.key, this.startupError});

  final String? startupError;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'UTRGV-GO',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'Inter',
        colorSchemeSeed: const Color(0xff123d2b),
      ),

      // Open authentication directly.
      // AuthGate handles signed-in and signed-out users.
      home: !AppConfiguration.hasBackend
          ? const Scaffold(
              body: Center(
                child: Text('Account service is not configured yet.'),
              ),
            )
          : startupError != null
          ? Scaffold(body: Center(child: Text(startupError!)))
          : const AuthGate(),
    );
  }
}
