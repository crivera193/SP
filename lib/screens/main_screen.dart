
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'map_screen.dart';

class MainScreen extends StatelessWidget {
  const MainScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      toolbarHeight: 44,
      backgroundColor: const Color(0xfff1f8eb),

title: const Text(
  'Edinburg Campus',
  style: TextStyle(
    color: Color(0xFF061E4A),
    fontSize: 18,
    fontWeight: FontWeight.w600,
  ),
),

      actions: [
        TextButton.icon(
          // Display text beside the logout icon.
          icon: const Icon(Icons.logout, size: 20),
          label: const Text(
            'Sign out',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),

          // Match the UTRGV-GO dark blue theme.
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF061E4A),
            padding: const EdgeInsets.symmetric(
              horizontal: 16,
            ),
          ),

          onPressed: () async {
            try {
              await Supabase.instance.client.auth.signOut();
            } catch (_) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Unable to sign out. Try again.',
                    ),
                  ),
                );
              }
            }
          },
        ),
      ],
    ),
    body: const MapScreen(),
  );
}
