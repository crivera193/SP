import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mb;
import '../player/latest_projection.dart';
import 'nearby_controller.dart';
import 'nearby_models.dart';
import 'friend_protocol.dart';
import 'friend_controller.dart';

class NearbyButton extends StatelessWidget {
  const NearbyButton({super.key, required this.controller});
  final NearbyController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => FilledButton.tonalIcon(
      key: const ValueKey('nearby-players'),
      icon: Icon(
        controller.running
            ? Icons.bluetooth_connected
            : Icons.bluetooth_searching,
      ),
      label: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 225),
        child: Text(
          controller.enabled ? controller.status : 'Nearby players',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => NearbyPanel(controller: controller),
      ),
    ),
  );
}

class NearbyPanel extends StatelessWidget {
  const NearbyPanel({super.key, required this.controller});
  final NearbyController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            20,
            20,
            20 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Nearby players',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              const Text(
                'Bluetooth finds players nearby. Only verified friends can open a communication session. Detection and friend sessions work without internet. Keep SP open.',
              ),
              const SizedBox(height: 12),
              Text(controller.status, key: const ValueKey('nearby-status')),
              if (controller.friends case final FriendController friends)
                ..._friendControls(context, friends),
              if (controller.peers.any((p) => p.position == null))
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Players without a fresh Bluetooth position are not shown on the map.',
                  ),
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (!controller.running && !controller.busy)
                    FilledButton(
                      onPressed: () => unawaited(controller.enable()),
                      child: Text(
                        controller.error == null ? 'Turn on' : 'Retry',
                      ),
                    ),
                  if (controller.enabled)
                    TextButton(
                      onPressed: () => unawaited(controller.disable()),
                      child: const Text('Turn off'),
                    ),
                  if (controller.error != null)
                    TextButton(
                      onPressed: () => unawaited(controller.openSettings()),
                      child: const Text('App settings'),
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
    ),
  );

  List<Widget> _friendControls(BuildContext context, FriendController friends) {
    final disabled = friends.busy || !controller.running;

    return [
      if (friends.error case final String error)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                error,
                key: const ValueKey('friend-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              TextButton(
                onPressed: disabled
                    ? null
                    : () => unawaited(controller.refresh()),
                child: const Text('Retry friend verification'),
              ),
            ],
          ),
        ),
      if (controller.peers.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text(
          'Detected players',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        for (final peer in controller.peers)
          ListTile(
            contentPadding: EdgeInsets.zero,
            key: ValueKey('detected-${peer.id}'),
            leading: Icon(
              peer.friendship == Friendship.accepted
                  ? Icons.verified_user
                  : Icons.person_outline,
            ),
            title: Text(peer.label),
            subtitle: Text(switch (peer.friendship) {
              Friendship.none => 'Detected · communication locked',
              Friendship.incoming => 'Wants to be your friend',
              Friendship.outgoing => 'Friend request sent',
              Friendship.accepted => 'Known friend · verify over Bluetooth',
            }),
            trailing: switch (peer.friendship) {
              Friendship.none =>
                peer.identityCode == null
                    ? const Icon(Icons.lock_outline)
                    : IconButton(
                        tooltip: 'Copy friend code',
                        icon: const Icon(Icons.copy),
                        onPressed: () => Clipboard.setData(
                          ClipboardData(
                            text: NearbyProtocol.friendCode(peer.identityCode!),
                          ),
                        ),
                      ),
              Friendship.incoming => const Icon(Icons.lock_outline),
              Friendship.outgoing => const Icon(Icons.schedule),
              Friendship.accepted =>
                friends.conversationFor(peer.id) == null
                    ? IconButton(
                        tooltip: 'Open Bluetooth session',
                        onPressed: disabled || friends.error != null
                            ? null
                            : () => unawaited(friends.open(peer.id)),
                        icon: const Icon(Icons.bluetooth_connected),
                      )
                    : const Icon(Icons.lock),
            },
          ),
      ],
      for (final conversation in friends.conversations)
        _FriendConversationCard(
          key: ValueKey(conversation.grant.id),
          controller: friends,
          conversation: conversation,
        ),
    ];
  }
}

class _FriendConversationCard extends StatelessWidget {
  const _FriendConversationCard({
    super.key,
    required this.controller,
    required this.conversation,
  });
  final FriendController controller;
  final FriendConversation conversation;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.lock_outline),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  conversation.grant.label,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: 'Close Bluetooth session',
                onPressed: () =>
                    unawaited(controller.close(conversation.grant.id)),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          Text(
            conversation.ready
                ? 'Verified Bluetooth session'
                : 'Waiting for your friend’s verified Bluetooth reply…',
          ),
        ],
      ),
    ),
  );
}

/// Projects only the already-authorized set. Coordinates never select players.
class NearbyMapLayer extends StatefulWidget {
  const NearbyMapLayer({
    super.key,
    required this.controller,
    required this.map,
    required this.cameraChanges,
    required this.active,
  });
  final NearbyController controller;
  final mb.MapboxMap? map;
  final ValueNotifier<int> cameraChanges;
  final bool active;
  @override
  State<NearbyMapLayer> createState() => _NearbyMapLayerState();
}

class _NearbyMapLayerState extends State<NearbyMapLayer> {
  late final LatestProjection<Map<String, Offset>> _projector;
  Map<String, Offset> _points = const {};
  @override
  void initState() {
    super.initState();
    _projector = LatestProjection(
      read: () async {
        final map = widget.map;
        if (map == null || !widget.active || !widget.controller.running) {
          return null;
        }
        final peers = widget.controller.peers
            .where((p) => p.position != null)
            .toList();
        if (peers.isEmpty) return const {};
        final pixels = await map.pixelsForCoordinates([
          for (final p in peers)
            mb.Point(
              coordinates: mb.Position(
                p.position!.longitude,
                p.position!.latitude,
              ),
            ),
        ]);
        return {
          for (var i = 0; i < peers.length && i < pixels.length; i++)
            if (pixels[i] case final mb.ScreenCoordinate pixel)
              if (pixel.x.isFinite && pixel.y.isFinite)
                peers[i].id: Offset(pixel.x, pixel.y),
        };
      },
      apply: (value) {
        if (mounted) setState(() => _points = value ?? const {});
      },
    );
    widget.controller.addListener(_changed);
    widget.cameraChanges.addListener(_changed);
    _changed();
  }

  void _changed() {
    if (mounted) {
      setState(
        () {},
      ); // Withdraw stale markers before native projection replies.
    }
    unawaited(_projector.request(invalidate: true));
  }

  @override
  void didUpdateWidget(NearbyMapLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _changed();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    widget.cameraChanges.removeListener(_changed);
    _projector.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: LayoutBuilder(
      builder: (context, bounds) => Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          if (widget.active && widget.controller.running)
            for (final peer in widget.controller.peers)
              if (_points[peer.id] case final Offset pixel)
                if (peer.position case final NearbyPosition fix)
                  if (peer.expiresAt.isAfter(DateTime.now()) &&
                      fix.expiresAt.isAfter(DateTime.now()) &&
                      pixel.dx >= 0 &&
                      pixel.dy >= 0 &&
                      pixel.dx <= bounds.maxWidth &&
                      pixel.dy <= bounds.maxHeight)
                    Positioned(
                      left: pixel.dx - 60,
                      top: pixel.dy - 53,
                      width: 120,
                      child: NearbyPlayerMarker(label: peer.label),
                    ),
        ],
      ),
    ),
  );
}

class NearbyPlayerMarker extends StatelessWidget {
  const NearbyPlayerMarker({super.key, required this.label});
  final String label;
  @override
  Widget build(BuildContext context) => Semantics(
    label: '$label, nearby over Bluetooth',
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: Color(0xff061e4a)),
          ),
        ),
        const Icon(Icons.person_pin_circle, size: 34, color: Color(0xff235aa6)),
      ],
    ),
  );
}
