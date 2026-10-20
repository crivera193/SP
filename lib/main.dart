import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'widgets/mapbox_configuration_notice.dart';
import 'auth/auth_gate.dart';
import 'config/app_configuration.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (hasMapboxConfiguration) MapboxOptions.setAccessToken(mapboxAccessToken);
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
          'Unable to connect to the account service. Please restart and try again.';
    }
  }
  runApp(CampusApp(startupError: startupError));
}

class CampusApp extends StatelessWidget {
  const CampusApp({super.key, this.startupError});
  final String? startupError;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'UTRGV-GO',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: 'Inter',
      colorSchemeSeed: const Color(0xff123d2b),
    ),
    home: const WelcomeScreen(),
    routes: {
      '/account': (_) => !AppConfiguration.hasBackend
          ? const Scaffold(
              body: Center(
                child: Text('Account service is not configured yet.'),
              ),
            )
          : startupError != null
          ? Scaffold(body: Center(child: Text(startupError!)))
          : const AuthGate(),
    },
  );
}

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xfff5f1e3),
    body: SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'UTRGV-GO',
                style: TextStyle(
                  fontFamily: 'DMSerifDisplay',
                  fontSize: 42,
                  color: Color(0xff123d2b),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Campus exploration starts here.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => Navigator.of(context).pushNamed('/account'),
                child: const Text('Get started'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
