import 'package:flutter/material.dart';
import 'online_friend_directory.dart';

class FriendDirectoryButton extends StatelessWidget {
  const FriendDirectoryButton({super.key, required this.directory});
  final OnlineFriendDirectory directory;
  @override
  Widget build(BuildContext context) => FilledButton.tonalIcon(
    icon: const Icon(Icons.people_outline),
    label: const Text('Friends'),
    onPressed: null,
  );
}

class FriendDirectoryPanel extends StatelessWidget {
  const FriendDirectoryPanel({super.key, required this.directory});
  final OnlineFriendDirectory directory;
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
