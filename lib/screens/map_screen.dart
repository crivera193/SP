import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size;
import '../map/campus_geography.dart';
import '../map/campus_style.dart';
import '../widgets/mapbox_configuration_notice.dart';

/// Campus geometry only. No location subscription or player/game integration.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  CampusGeography? _geography;
  MapboxMap? _map;
  String? _styleUri, _error;
  bool _styleLoaded = false, _preparing = false, _ready = false;

  @override
  void initState() {
    super.initState();
    if (hasMapboxConfiguration) unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final boundary = await rootBundle.loadString(
        'assets/campus/boundary.geojson',
      );
      final data = await rootBundle.loadString(
        'assets/campus/features.geojson',
      );
      final geography = CampusGeography.fromGeoJson(boundary);
      final directory = await Directory.systemTemp.createTemp('utrgv-campus-');
      final file = await File('${directory.path}/style.json').writeAsString(
        jsonEncode(CampusStyle.build(boundary, data)),
        flush: true,
      );
      if (!mounted) return;
      setState(() {
        _geography = geography;
        _styleUri = file.uri.toString();
        _map = null;
        _styleLoaded = false;
        _preparing = false;
        _ready = false;
        _error = null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Unable to load campus data.');
    }
  }

  Point _point(CampusPoint p) =>
      Point(coordinates: Position(p.longitude, p.latitude));

  Future<void> _prepare() async {
    final map = _map, campus = _geography;
    if (map == null || campus == null || !_styleLoaded || _preparing || _ready)
      return;
    _preparing = true;
    try {
      await map.setBounds(
        CameraBoundsOptions(
          bounds: CoordinateBounds(
            southwest: _point(CampusPoint(campus.west, campus.south)),
            northeast: _point(CampusPoint(campus.east, campus.north)),
            infiniteBounds: false,
          ),
          minZoom: 12,
          maxZoom: 19.5,
          minPitch: 45,
          maxPitch: 45,
        ),
      );
      await map.gestures.updateSettings(
        GesturesSettings(
          rotateEnabled: false,
          simultaneousRotateAndPinchToZoomEnabled: false,
          pitchEnabled: false,
        ),
      );
      await map.location.updateSettings(
        LocationComponentSettings(enabled: false),
      );
      await map.scaleBar.updateSettings(ScaleBarSettings(enabled: false));
      final fit = await map.cameraForCoordinatesPadding(
        campus.outerPoints.map(_point).toList(),
        CameraOptions(
          pitch: 45,
          bearing: 0,
          padding: MbxEdgeInsets(top: 24, left: 24, bottom: 48, right: 24),
        ),
        null,
        17,
        null,
      );
      await map.setBounds(
        CameraBoundsOptions(minZoom: (fit.zoom ?? 14).clamp(12, 19.5)),
      );
      await map.setCamera(fit);
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      if (mounted) setState(() => _error = 'Campus map could not load.');
    } finally {
      _preparing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!hasMapboxConfiguration) return const MapboxConfigurationNotice();
    return ColoredBox(
      color: const Color(0xffc9ddd3),
      child: Stack(
        children: [
          if (_styleUri != null)
            MapWidget(
              key: ValueKey(_styleUri),
              styleUri: _styleUri!,
              viewport: CameraViewportState(
                center: _point(_geography!.center),
                zoom: 15,
                pitch: 45,
                bearing: 0,
              ),
              onMapCreated: (map) {
                _map = map;
                unawaited(_prepare());
              },
              onStyleLoadedListener: (_) {
                _styleLoaded = true;
                unawaited(_prepare());
              },
              onMapLoadErrorListener: (event) {
                if (event.type == MapLoadErrorType.GLYPHS) return;
                if (mounted)
                  setState(() => _error = 'Campus map could not load.');
              },
            ),
          if (!_ready || _error != null)
            Positioned.fill(
              child: ColoredBox(
                color: const Color(0xffc9ddd3),
                child: Center(
                  child: _error == null
                      ? const CircularProgressIndicator()
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_error!),
                            TextButton(
                              onPressed: _load,
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
