
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart'
    hide Size;

import '../map/campus_geography.dart';
import '../map/campus_style.dart';
import '../widgets/mapbox_configuration_notice.dart';

/// Campus-only Mapbox screen.
///
/// Displays:
/// - UTRGV campus geometry
/// - 3D buildings
/// - Sidewalks and roads
/// - Official UTRGV building abbreviations
///
/// No GPS player or game integration.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  // UTRGV Edinburg Student Union.
  static const double _startLatitude = 26.30546;
  static const double _startLongitude = -98.17525;

  static const double _startZoom = 16.5;
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

  /// Merge official building names with existing
  /// campus GeoJSON using OpenStreetMap IDs.
  String _applyBuildingLabels(
    String geographyJson,
    String buildingLabelsJson,
  ) {
    final geography =
        jsonDecode(geographyJson) as Map<String, dynamic>;

    final labelsData =
        jsonDecode(buildingLabelsJson) as Map<String, dynamic>;

    final features = geography['features'] as List;
    final labels = labelsData['labels'] as List;

    final labelLookup = <String, Map<String, dynamic>>{};

    // Build lookup table of verified building labels.
    for (final item in labels) {
      final entry = item as Map<String, dynamic>;

      if (entry['verified_name'] != true) {
        continue;
      }

      final osmId = entry['osm_id'] as String?;
      final code = entry['code'] as String?;

      if (osmId == null ||
          code == null ||
          code.isEmpty) {
        continue;
      }

      labelLookup.putIfAbsent(
        osmId,
        () => entry,
      );
    }

    // Track buildings that have already received labels.
    final labeledBuildings = <String>{};

    for (final item in features) {
      final feature = item as Map<String, dynamic>;

      final properties =
          feature['properties'] as Map<String, dynamic>;

      if (properties['kind'] != 'building') {
        continue;
      }

      final osmId = properties['osm_id'] as String?;

      if (osmId == null) {
        continue;
      }

      final building = labelLookup[osmId];

      if (building == null) {
        // Keep existing labels where a verified
        // building mapping is unavailable.
        continue;
      }

      // Prevent duplicate labels.
      if (labeledBuildings.contains(osmId)) {
        properties.remove('label');
        continue;
      }

      labeledBuildings.add(osmId);

      // Short official building code shown on map.
      properties['label'] = building['code'];

      // Full name for future building information popup.
      properties['official_name'] = building['name'];

      // Building abbreviation.
      properties['building_code'] = building['code'];
    }

    return jsonEncode(geography);
  }

  /// Load campus geometry and official labels.
  Future<void> _load() async {
    try {
      // Campus boundary.
      final boundary = await rootBundle.loadString(
        'assets/campus/boundary.geojson',
      );

      // Original building, road, and sidewalk geometry.
      final data = await rootBundle.loadString(
        'assets/campus/features.geojson',
      );

      // Official UTRGV building labels.
      final buildingLabels = await rootBundle.loadString(
        'assets/campus/building-labels.json',
      );

      // Merge building abbreviations into the map data.
      final updatedData = _applyBuildingLabels(
        data,
        buildingLabels,
      );

      final geography = CampusGeography.fromGeoJson(
        boundary,
      );

      // Generate local custom Mapbox style.
      final directory =
          await Directory.systemTemp.createTemp(
        'utrgv-campus-',
      );

      final file = await File(
        '${directory.path}/style.json',
      ).writeAsString(
        jsonEncode(
          CampusStyle.build(
            boundary,
            updatedData,
          ),
        ),
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
    } catch (error) {
      debugPrint(
        'UTRGV campus loading error: $error',
      );

      if (mounted) {
        setState(() {
          _error = 'Unable to load campus data.';
        });
      }
    }
  }

  /// Convert campus longitude and latitude
  /// to a Mapbox Point.
  Point _point(CampusPoint point) {
    return Point(
      coordinates: Position(
        point.longitude,
        point.latitude,
      ),
    );
  }

  /// Initial camera position over Student Union.
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

  /// Configure Mapbox camera restrictions.
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
      // Limit camera to UTRGV campus.
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

      // Allow panning and zooming,
      // but prevent rotation and pitch changes.
      await map.gestures.updateSettings(
        GesturesSettings(
          rotateEnabled: false,
          simultaneousRotateAndPinchToZoomEnabled: false,
          pitchEnabled: false,
        ),
      );

      // Disable device location indicator.
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

      // Open over Student Union.
      await map.setCamera(
        _openingCamera,
      );

      if (mounted) {
        setState(() {
          _ready = true;
        });
      }
    } catch (error) {
      debugPrint(
        'UTRGV Mapbox preparation error: $error',
      );

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
                if (event.type ==
                    MapLoadErrorType.GLYPHS) {
                  return;
                }

                if (mounted) {
                  setState(() {
                    _error =
                        'Campus map could not load.';
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
