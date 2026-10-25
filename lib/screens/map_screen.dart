
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size;

import '../map/campus_geography.dart';
import '../map/campus_style.dart';
import '../widgets/mapbox_configuration_notice.dart';

/// Campus geometry only.
/// No location subscription or player/game integration.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  // UTRGV Edinburg campus opening coordinates.
  static const double _startLatitude = 26.30546;
  static const double _startLongitude = -98.17525;

  static const double _startZoom = 18.5;
  static const double _startPitch = 45.0;

  CampusGeography? _geography;
  MapboxMap? _map;

  String? _styleUri;
  String? _error;

  bool _styleLoaded = false;
  bool _preparing = false;
  bool _ready = false;

  @override
  void initState() {
    super.initState();

    if (hasMapboxConfiguration) {
      unawaited(_load());
    }
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

      final directory = await Directory.systemTemp.createTemp(
        'utrgv-campus-',
      );

      final file = await File(
        '${directory.path}/style.json',
      ).writeAsString(
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
      if (mounted) {
        setState(() {
          _error = 'Unable to load campus data.';
        });
      }
    }
  }

  Point _point(CampusPoint p) {
    return Point(
      coordinates: Position(
        p.longitude,
        p.latitude,
      ),
    );
  }

  /// Opening camera centered on UTRGV Edinburg.
  CameraOptions get _openingCamera {
    return CameraOptions(
      center: Point(
        coordinates: Position(
          _startLongitude,
          _startLatitude,
        ),
      ),
      zoom: _startZoom,
      pitch: _startPitch,
      bearing: 0,
      padding: MbxEdgeInsets(
        top: 0,
        left: 0,
        bottom: 0,
        right: 0,
      ),
    );
  }

  Future<void> _prepare() async {
    final map = _map;
    final campus = _geography;

    if (map == null ||
        campus == null ||
        !_styleLoaded ||
        _preparing ||
        _ready) {
      return;
    }

    _preparing = true;

    try {
      // Restrict camera movement to UTRGV campus.
      await map.setBounds(
        CameraBoundsOptions(
          bounds: CoordinateBounds(
            southwest: _point(
              CampusPoint(
                campus.west,
                campus.south,
              ),
            ),
            northeast: _point(
              CampusPoint(
                campus.east,
                campus.north,
              ),
            ),
            infiniteBounds: false,
          ),
          minZoom: 12,
          maxZoom: 19.5,
          minPitch: _startPitch,
          maxPitch: _startPitch,
        ),
      );

      // Allow panning and zooming.
      // Disable camera rotation and pitch gestures.
      await map.gestures.updateSettings(
        GesturesSettings(
          rotateEnabled: false,
          simultaneousRotateAndPinchToZoomEnabled: false,
          pitchEnabled: false,
        ),
      );

      // Disable user location indicator.
      await map.location.updateSettings(
        LocationComponentSettings(
          enabled: false,
        ),
      );

      // Hide scale bar.
      await map.scaleBar.updateSettings(
        ScaleBarSettings(
          enabled: false,
        ),
      );

      // Set the exact opening camera instead of
      // automatically fitting the entire campus.
      await map.setCamera(_openingCamera);

      if (mounted) {
        setState(() {
          _ready = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Campus map could not load.';
        });
      }
    } finally {
      _preparing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!hasMapboxConfiguration) {
      return const MapboxConfigurationNotice();
    }

    return ColoredBox(
      color: const Color(0xffc9ddd3),
      child: Stack(
        children: [
          if (_styleUri != null)
            MapWidget(
              key: ValueKey(_styleUri),
              styleUri: _styleUri!,

              // Initial map position.
              viewport: CameraViewportState(
                center: Point(
                  coordinates: Position(
                    _startLongitude,
                    _startLatitude,
                  ),
                ),
                zoom: _startZoom,
                pitch: _startPitch,
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
                if (event.type == MapLoadErrorType.GLYPHS) {
                  return;
                }

                if (mounted) {
                  setState(() {
                    _error = 'Campus map could not load.';
                  });
                }
              },
            ),

          // Loading and error overlay.
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
