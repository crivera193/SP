import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mb;
import '../player/latest_projection.dart';
import 'nearby_controller.dart';
import 'nearby_models.dart';

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
          padding: const EdgeInsets.all(20),
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
                'Turn Bluetooth on to wrangle some friends nearby.',
              ),
              const SizedBox(height: 12),
              Text(controller.status, key: const ValueKey('nearby-status')),
              if (controller.peers.any((p) => p.position == null))
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Some detected players are waiting for a fresh map position.',
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
