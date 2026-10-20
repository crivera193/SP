import 'package:flutter/material.dart';

void main() => runApp(const CampusApp());

class CampusApp extends StatelessWidget {
  const CampusApp({super.key});
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
      '/account': (_) => const Scaffold(
        body: Center(child: Text('Account screens coming next.')),
      ),
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
