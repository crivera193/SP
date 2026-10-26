
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart' as gps;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart'
    hide Size;

import '../map/campus_geography.dart';
import '../map/campus_style.dart';
import '../widgets/mapbox_configuration_notice.dart';

/// UTRGV-GO campus map.
///
/// Features:
/// - 3D buildings and sidewalks
/// - Official building abbreviations
/// - Campus-only camera restrictions
/// - Adjustable zoom and pitch
/// - Live GPS location
/// - GPS-follow camera
/// - Zoom controls
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {

  // ==========================================
  // MAPBOX CAMERA CONFIGURATION
  // ==========================================

  // UTRGV Student Union starting position.
  static const double _startLatitude = 26.30546;
  static const double _startLongitude = -98.17525;

  // Initial zoom when opening the map.
  static const double _startZoom = 17.8;

  // Zoom when following the GPS player.
  static const double _followZoom = 18.0;

  // Map zoom limits.
  static const double _minZoom = 14.0;
  static const double _maxZoom = 19.5;

  // Camera tilt in degrees.
  // 0 = directly overhead.
  // 45 = tilted 3D-style perspective.
  // 60 = steeper viewing angle.
  static const double _cameraPitch = 45.0;

  // Camera rotation.
  static const double _cameraBearing = 0.0;

  // ==========================================
  // GPS CONFIGURATION
  // ==========================================

  // Requested GPS update interval on Android.
  static const Duration _androidGpsInterval =
      Duration(seconds: 1);

  // 0 = accept location changes without
  // a minimum distance threshold.
  static const int _gpsDistanceFilterMeters = 0;

  // ==========================================
  // MAPBOX STATE
  // ==========================================

  CampusGeography? _geography;
  MapboxMap? _map;

  String? _styleUri;
  String? _error;
  String? _locationMessage;

  bool _styleLoaded = false;
  bool _preparing = false;
  bool _ready = false;

  // ==========================================
  // GPS STATE
  // ==========================================

  bool _following = false;
  bool _locating = false;

  gps.Position? _lastPosition;

  StreamSubscription<gps.Position>? _gpsSubscription;

  Offset? _markerPixel;

  bool _projectionBusy = false;
  bool _projectionAgain = false;

  // ==========================================
  // INITIALIZATION
  // ==========================================

  @override
  void initState() {
    super.initState();

    if (hasMapboxConfiguration) {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    unawaited(_gpsSubscription?.cancel());
    super.dispose();
  }

  // ==========================================
  // BUILDING LABELS
  // ==========================================

  /// Adds official UTRGV building abbreviations
  /// to existing campus GeoJSON features.
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

    final lookup = <String, Map<String, dynamic>>{};

    // Only use verified building names.
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

      lookup.putIfAbsent(
        osmId,
        () => entry,
      );
    }

    final labeledBuildings = <String>{};

    for (final item in features) {
      final feature = item as Map<String, dynamic>;

      final properties =
          feature['properties'] as Map<String, dynamic>;

      if (properties['kind'] != 'building') {
        continue;
      }

      final osmId = properties['osm_id'] as String?;

      if (osmId == null) continue;

      final building = lookup[osmId];

      if (building == null) continue;

      // Avoid duplicate labels for multipart buildings.
      if (labeledBuildings.contains(osmId)) {
        properties.remove('label');
        continue;
      }

      labeledBuildings.add(osmId);

      properties['label'] = building['code'];
      properties['official_name'] = building['name'];
      properties['building_code'] = building['code'];
    }

    return jsonEncode(geography);
  }

  // ==========================================
  // LOAD CAMPUS MAP
  // ==========================================

  Future<void> _load() async {
    try {
      final boundary = await rootBundle.loadString(
        'assets/campus/boundary.geojson',
      );

      final data = await rootBundle.loadString(
        'assets/campus/features.geojson',
      );

      final buildingLabels = await rootBundle.loadString(
        'assets/campus/building-labels.json',
      );

      final updatedData = _applyBuildingLabels(
        data,
        buildingLabels,
      );

      final geography =
          CampusGeography.fromGeoJson(boundary);

      // Generate custom Mapbox style.
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

        _markerPixel = null;
        _error = null;
      });
    } catch (error) {
      debugPrint(
        'Campus loading error: $error',
      );

      if (mounted) {
        setState(() {
          _error = 'Unable to load campus data.';
        });
      }
    }
  }

  // ==========================================
  // MAPBOX COORDINATES
  // ==========================================

  Point _point(CampusPoint point) {
    return Point(
      coordinates: Position(
        point.longitude,
        point.latitude,
      ),
    );
  }

  // ==========================================
  // OPENING CAMERA
  // ==========================================

  CameraOptions get _openingCamera {
    return CameraOptions(
      center: Point(
        coordinates: Position(
          _startLongitude,
          _startLatitude,
        ),
      ),
      zoom: _startZoom,
      pitch: _cameraPitch,
      bearing: _cameraBearing,
      padding: MbxEdgeInsets(
        top: 0,
        left: 0,
        bottom: 0,
        right: 0,
      ),
    );
  }

  // ==========================================
  // CAMERA RESTRICTIONS
  // ==========================================

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
      // Constrain camera to campus bounds.
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
          minZoom: _minZoom,
          maxZoom: _maxZoom,
          minPitch: _cameraPitch,
          maxPitch: _cameraPitch,
        ),
      );

      // Allow panning and zooming.
      // Disable rotation and manual pitch gestures.
      await map.gestures.updateSettings(
        GesturesSettings(
          rotateEnabled: false,
          simultaneousRotateAndPinchToZoomEnabled: false,
          pitchEnabled: false,
          pinchToZoomEnabled: true,
          scrollEnabled: true,
        ),
      );

      // Disable Mapbox's native location puck.
      // A custom GPS marker will be shown instead.
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

      // Set initial position over Student Union.
      await map.setCamera(_openingCamera);

      if (mounted) {
        setState(() {
          _ready = true;
        });
      }
    } catch (error) {
      debugPrint(
        'Mapbox setup error: $error',
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

  // ==========================================
  // ZOOM CONTROLS
  // ==========================================

  Future<void> _zoomBy(double delta) async {
    final map = _map;

    if (map == null || !_ready) return;

    // Manual zoom disables camera following.
    _stopFollowing();

    try {
      final camera = await map.getCameraState();

      final nextZoom = (camera.zoom + delta)
          .clamp(_minZoom, _maxZoom)
          .toDouble();

      await map.setCamera(
        CameraOptions(
          zoom: nextZoom,
        ),
      );

      unawaited(_projectMarker());
    } catch (error) {
      debugPrint(
        'Unable to zoom map: $error',
      );
    }
  }

  // ==========================================
  // START GPS FOLLOWING
  // ==========================================

  Future<void> _beginGpsFollow() async {
    if (_locating || !_ready) return;

    setState(() {
      _locating = true;
      _locationMessage = null;
    });

    try {
      final enabled =
          await gps.Geolocator.isLocationServiceEnabled();

      if (!enabled) {
        throw StateError(
          'Enable location services on your device.',
        );
      }

      var permission =
          await gps.Geolocator.checkPermission();

      if (permission == gps.LocationPermission.denied) {
        permission =
            await gps.Geolocator.requestPermission();
      }

      if (permission == gps.LocationPermission.denied ||
          permission ==
              gps.LocationPermission.deniedForever) {
        throw StateError(
          'Location permission is required.',
        );
      }

      if (!mounted) return;

      setState(() {
        _following = true;
      });

      await _gpsSubscription?.cancel();

      // Subscribe to live GPS updates.
      _gpsSubscription =
          gps.Geolocator.getPositionStream(
        locationSettings: Platform.isAndroid
            ? gps.AndroidSettings(
                accuracy: gps.LocationAccuracy.high,
                distanceFilter:
                    _gpsDistanceFilterMeters,
                intervalDuration: _androidGpsInterval,
              )
            : const gps.LocationSettings(
                accuracy: gps.LocationAccuracy.high,
                distanceFilter:
                    _gpsDistanceFilterMeters,
              ),
      ).listen(
        _onGpsFix,
        onError: (Object error) {
          if (mounted) {
            setState(() {
              _following = false;
              _locationMessage =
                  'GPS updates unavailable.';
            });
          }
        },
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _locationMessage = error is StateError
              ? error.message
              : 'Could not start GPS.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _locating = false;
        });
      }
    }
  }

  // ==========================================
  // STOP CAMERA FOLLOWING
  // ==========================================

  void _stopFollowing() {
    if (_following && mounted) {
      setState(() {
        _following = false;
      });
    }
  }

  // ==========================================
  // RECEIVE GPS COORDINATES
  // ==========================================

  void _onGpsFix(gps.Position position) {
    if (!mounted || !_ready) return;

    final campus = _geography;

    if (campus == null) return;

    final point = CampusPoint(
      position.longitude,
      position.latitude,
    );

    // Player marker only appears on campus.
    if (!campus.contains(point)) {
      setState(() {
        _lastPosition = null;
        _markerPixel = null;
        _following = false;
        _locationMessage =
            'GPS position is outside the campus boundary.';
      });

      return;
    }

    setState(() {
      _lastPosition = position;
      _locationMessage = null;
    });

    // Update marker position.
    unawaited(_projectMarker());

    // Move camera only when GPS follow is enabled.
    if (_following) {
      unawaited(_followPosition(point));
    }
  }

  // ==========================================
  // GPS FOLLOW CAMERA
  // ==========================================

  Future<void> _followPosition(
    CampusPoint point,
  ) async {
    final map = _map;

    if (map == null || !_ready || !_following) {
      return;
    }

    try {
      await map.setCamera(
        CameraOptions(
          center: _point(point),

          // GPS follow zoom.
          zoom: _followZoom
              .clamp(_minZoom, _maxZoom)
              .toDouble(),

          // Fixed tilted camera.
          pitch: _cameraPitch,

          // Keep north pointing upward.
          bearing: _cameraBearing,
        ),
      );

      await _projectMarker();
    } catch (error) {
      debugPrint(
        'GPS camera update failed: $error',
      );
    }
  }

  // ==========================================
  // GPS MARKER SCREEN POSITION
  // ==========================================

  /// Converts geographic GPS coordinates
  /// to Flutter screen coordinates.
  Future<void> _projectMarker() async {
    if (_projectionBusy) {
      _projectionAgain = true;
      return;
    }

    _projectionBusy = true;

    try {
      do {
        _projectionAgain = false;

        final map = _map;
        final position = _lastPosition;

        if (map == null ||
            position == null ||
            !_ready) {
          break;
        }

        final pixel = await map.pixelForCoordinate(
          _point(
            CampusPoint(
              position.longitude,
              position.latitude,
            ),
          ),
        );

        if (!mounted) break;

        setState(() {
          if (pixel.x.isFinite && pixel.y.isFinite) {
            _markerPixel = Offset(
              pixel.x,
              pixel.y,
            );
          } else {
            _markerPixel = null;
          }
        });
      } while (_projectionAgain);
    } catch (error) {
      debugPrint(
        'GPS marker projection failed: $error',
      );
    } finally {
      _projectionBusy = false;
    }
  }

  // ==========================================
  // MAP SCREEN UI
  // ==========================================

  @override
  Widget build(BuildContext context) {
    if (!hasMapboxConfiguration) {
      return const MapboxConfigurationNotice();
    }

    return ColoredBox(
      color: const Color(0xffc9ddd3),
      child: Stack(
        children: [
          // ==================================
          // MAPBOX WIDGET
          // ==================================

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
                pitch: _cameraPitch,
                bearing: _cameraBearing,
              ),

              // Stop following when manually moving map.
              onScrollListener: (_) {
                _stopFollowing();
              },

              onZoomListener: (_) {
                _stopFollowing();
              },

              // Update GPS marker during camera movement.
              onCameraChangeListener: (_) {
                unawaited(_projectMarker());
              },

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
                    _error = 'Campus map could not load.';
                  });
                }
              },
            ),

          // ==================================
          // GPS LOCATION MARKER
          // ==================================

          if (_ready && _markerPixel != null)
            Positioned(
              left: _markerPixel!.dx - 10,
              top: _markerPixel!.dy - 10,
              child: IgnorePointer(
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: const Color(0xff061e4a),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white,
                      width: 3,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black26,
                        blurRadius: 6,
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // ==================================
          // GPS AND ZOOM BUTTONS
          // ==================================

          if (_ready)
            Positioned(
              right: 12,
              bottom: 18,
              child: SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // GPS follow button.
                    FloatingActionButton.small(
                      heroTag: 'campus-follow',
                      tooltip: _following
                          ? 'GPS following'
                          : 'Follow my GPS',
                      onPressed: _locating
                          ? null
                          : () {
                              if (_following) {
                                _stopFollowing();
                              } else {
                                unawaited(
                                  _beginGpsFollow(),
                                );
                              }
                            },
                      child: Icon(
                        _following
                            ? Icons.gps_fixed
                            : Icons.my_location,
                      ),
                    ),

                    const SizedBox(height: 10),

                    // Zoom in.
                    FloatingActionButton.small(
                      heroTag: 'campus-zoom-in',
                      tooltip: 'Zoom in',
                      onPressed: () {
                        unawaited(_zoomBy(0.5));
                      },
                      child: const Icon(Icons.add),
                    ),

                    const SizedBox(height: 8),

                    // Zoom out.
                    FloatingActionButton.small(
                      heroTag: 'campus-zoom-out',
                      tooltip: 'Zoom out',
                      onPressed: () {
                        unawaited(_zoomBy(-0.5));
                      },
                      child: const Icon(Icons.remove),
                    ),
                  ],
                ),
              ),
            ),

          // ==================================
          // LOCATION MESSAGE
          // ==================================

          if (_locationMessage != null && _ready)
            Positioned(
              left: 12,
              right: 76,
              bottom: 20,
              child: Material(
                color: const Color(0xfff5f1e3),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Text(
                    _locationMessage!,
                    style: const TextStyle(
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),

          // ==================================
          // LOADING / ERROR OVERLAY
          // ==================================

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
