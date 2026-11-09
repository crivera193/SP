import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'map_screen.dart';
import '../teams/team_membership.dart';

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
        IconButton(
          tooltip: 'Your permanent team',
          icon: const Icon(Icons.groups_outlined),
          onPressed: () {
            final team = TeamScope.of(context).team!;
            showDialog<void>(
              context: context,
              useRootNavigator: false,
              builder: (context) => AlertDialog(
                title: Text(team.displayName),
                content: Text(
                  '${team.colorName} team\n\nYour choice stays with this account.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close'),
                  ),
                ],
              ),
            );
          },
        ),
        TextButton.icon(
          // Display text beside the logout icon.
          icon: const Icon(Icons.logout, size: 20),
          label: const Text(
            'Sign out',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),

          // Match the UTRGV-GO dark blue theme.
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF061E4A),
            padding: const EdgeInsets.symmetric(horizontal: 16),
          ),

          onPressed: () async {
            try {
              await Supabase.instance.client.auth.signOut();
            } catch (_) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Unable to sign out. Try again.'),
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
