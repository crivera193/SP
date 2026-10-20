import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class MainScreen extends StatelessWidget {
  const MainScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('UTRGV-GO'),
      actions: [
        IconButton(
          tooltip: 'Sign out',
          icon: const Icon(Icons.logout),
          onPressed: () async {
            try {
              await Supabase.instance.client.auth.signOut();
            } catch (_) {
              if (context.mounted)
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Unable to sign out. Try again.'),
                  ),
                );
            }
          },
        ),
      ],
    ),
    body: const Center(child: Text('Signed in.')),
  );
}
