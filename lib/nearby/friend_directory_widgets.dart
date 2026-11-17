import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'friend_protocol.dart';
import 'online_friend_directory.dart';
import 'nearby_models.dart';

class FriendDirectoryButton extends StatelessWidget {
  const FriendDirectoryButton({super.key, required this.directory});
  final OnlineFriendDirectory directory;
  @override
  Widget build(BuildContext context) => FilledButton.tonalIcon(
    icon: const Icon(Icons.people_outline),
    label: const Text('Friends'),
    onPressed: () => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => FriendDirectoryPanel(directory: directory),
    ),
  );
}

class FriendDirectoryPanel extends StatefulWidget {
  const FriendDirectoryPanel({super.key, required this.directory});
  final OnlineFriendDirectory directory;
  @override
  State<FriendDirectoryPanel> createState() => _FriendDirectoryPanelState();
}

class _FriendDirectoryPanelState extends State<FriendDirectoryPanel> {
  final _code = TextEditingController();
  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.directory, widget.directory.book]),
    builder: (context, _) {
      final d = widget.directory, book = d.book;
      return SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              20,
              20,
              20 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Friends', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                const Text(
                  'Verify your friend list here while online. Nearby players and friend Bluetooth sessions work without internet using that verified list.',
                ),
                if (book.selfCode != null)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Your friend code'),
                    subtitle: SelectableText(
                      NearbyProtocol.friendCode(book.selfCode!),
                    ),
                    trailing: IconButton(
                      tooltip: 'Copy your friend code',
                      icon: const Icon(Icons.copy),
                      onPressed: () => Clipboard.setData(
                        ClipboardData(
                          text: NearbyProtocol.friendCode(book.selfCode!),
                        ),
                      ),
                    ),
                  ),
                TextField(
                  controller: _code,
                  decoration: const InputDecoration(
                    labelText: 'Friend code',
                    hintText: 'ABCD-1234',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: d.busy
                      ? null
                      : () => unawaited(d.request(_code.text)),
                  child: const Text('Send friend request'),
                ),
                if (d.error != null)
                  Text(
                    d.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (!book.valid)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Refresh your verified friends before opening a Bluetooth session.',
                    ),
                  ),
                for (final f in book.friends)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(f.label),
                    subtitle: Text(switch (f.status) {
                      Friendship.accepted => 'Verified friend',
                      Friendship.incoming => 'Incoming request',
                      _ => 'Request sent',
                    }),
                    trailing: PopupMenuButton<String>(
                      tooltip: 'Manage ${f.label}',
                      enabled: !d.busy,
                      onSelected: (action) =>
                          unawaited(d.respond(f.id, action)),
                      itemBuilder: (_) => [
                        if (f.status == Friendship.incoming)
                          const PopupMenuItem(
                            value: 'accept',
                            child: Text('Accept friend'),
                          ),
                        PopupMenuItem(
                          value: 'remove',
                          child: Text(
                            f.status == Friendship.accepted
                                ? 'Remove friend'
                                : 'Cancel / decline',
                          ),
                        ),
                      ],
                    ),
                  ),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: d.busy ? null : () => unawaited(d.refresh()),
                      child: const Text('Refresh friends'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
