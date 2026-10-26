import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart' as gps;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size;

import '../map/campus_geography.dart';
import '../map/campus_style.dart';
import '../player/cowboy_motion.dart';
import '../player/cowboy_sprite.dart';
import '../widgets/mapbox_configuration_notice.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  // ==========================================
  // CAMERA CONFIGURATION
  // ==========================================

  static const double _startLatitude = 26.30546;
  static const double _startLongitude = -98.17525;

  static const double _startZoom = 17.8;
  static const double _followZoom = 18.0;

  static const double _minZoom = 14.0;
  static const double _maxZoom = 19.5;

  static const double _cameraPitch = 45.0;
  static const double _cameraBearing = 0.0;

  // ==========================================
  // GPS CONFIGURATION
  // ==========================================

  static const Duration _androidGpsInterval = Duration(seconds: 1);

  static const int _gpsDistanceFilterMeters = 0;

  // ==========================================
  // MAP STATE
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

  bool _projectionBusy = false;
  bool _projectionAgain = false;

  // ==========================================
  // VAQUERO STATE
  // ==========================================

  final CowboyMotion _cowboyMotion = CowboyMotion();

  final ValueNotifier<CowboyPlacement?> _cowboyPlacement =
      ValueNotifier<CowboyPlacement?>(null);

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

    _cowboyPlacement.dispose();

    super.dispose();
  }

  // ==========================================
  // BUILDING LABELS
  // ==========================================

  String _applyBuildingLabels(String geographyJson, String buildingLabelsJson) {
    final geography = jsonDecode(geographyJson) as Map<String, dynamic>;

    final labelsData = jsonDecode(buildingLabelsJson) as Map<String, dynamic>;

    final features = geography['features'] as List;
    final labels = labelsData['labels'] as List;

    final lookup = <String, Map<String, dynamic>>{};

    for (final item in labels) {
      final entry = item as Map<String, dynamic>;

      if (entry['verified_name'] != true) {
        continue;
      }

      final osmId = entry['osm_id'] as String?;
      final code = entry['code'] as String?;

      if (osmId == null || code == null || code.isEmpty) {
        continue;
      }

      lookup.putIfAbsent(osmId, () => entry);
    }

    final labeledBuildings = <String>{};

    for (final item in features) {
      final feature = item as Map<String, dynamic>;

      final properties = feature['properties'] as Map<String, dynamic>;

      if (properties['kind'] != 'building') {
        continue;
      }

      final osmId = properties['osm_id'] as String?;

      if (osmId == null) continue;

      final building = lookup[osmId];

      if (building == null) continue;

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
  // LOAD CAMPUS DATA
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

      final updatedData = _applyBuildingLabels(data, buildingLabels);

      final geography = CampusGeography.fromGeoJson(boundary);

      final directory = await Directory.systemTemp.createTemp('utrgv-campus-');

      final file = await File('${directory.path}/style.json').writeAsString(
        jsonEncode(CampusStyle.build(boundary, updatedData)),
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

      _cowboyPlacement.value = null;
    } catch (error) {
      debugPrint('Campus loading error: $error');

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
    return Point(coordinates: Position(point.longitude, point.latitude));
  }

  // ==========================================
  // OPENING CAMERA
  // ==========================================

  CameraOptions get _openingCamera {
    return CameraOptions(
      center: Point(coordinates: Position(_startLongitude, _startLatitude)),
      zoom: _startZoom,
      pitch: _cameraPitch,
      bearing: _cameraBearing,
      padding: MbxEdgeInsets(top: 0, left: 0, bottom: 0, right: 0),
    );
  }

  // ==========================================
  // CONFIGURE MAPBOX
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
      await map.setBounds(
        CameraBoundsOptions(
          bounds: CoordinateBounds(
            southwest: _point(CampusPoint(campus.west, campus.south)),
            northeast: _point(CampusPoint(campus.east, campus.north)),
            infiniteBounds: false,
          ),
          minZoom: _minZoom,
          maxZoom: _maxZoom,
          minPitch: _cameraPitch,
          maxPitch: _cameraPitch,
        ),
      );

      await map.gestures.updateSettings(
        GesturesSettings(
          rotateEnabled: false,
          simultaneousRotateAndPinchToZoomEnabled: false,
          pitchEnabled: false,
          pinchToZoomEnabled: true,
          scrollEnabled: true,
        ),
      );

      // The custom Vaquero replaces the native GPS puck.
      await map.location.updateSettings(
        LocationComponentSettings(enabled: false),
      );

      await map.scaleBar.updateSettings(ScaleBarSettings(enabled: false));

      await map.setCamera(_openingCamera);

      if (mounted) {
        setState(() {
          _ready = true;
        });
      }

      unawaited(_projectCowboy());
    } catch (error) {
      debugPrint('Mapbox setup error: $error');

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

    _stopFollowing();

    try {
      final camera = await map.getCameraState();

      final nextZoom = (camera.zoom + delta)
          .clamp(_minZoom, _maxZoom)
          .toDouble();

      await map.setCamera(CameraOptions(zoom: nextZoom));

      unawaited(_projectCowboy());
    } catch (error) {
      debugPrint('Unable to zoom map: $error');
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
      final enabled = await gps.Geolocator.isLocationServiceEnabled();

      if (!enabled) {
        throw StateError('Enable location services on your device.');
      }

      var permission = await gps.Geolocator.checkPermission();

      if (permission == gps.LocationPermission.denied) {
        permission = await gps.Geolocator.requestPermission();
      }

      if (permission == gps.LocationPermission.denied ||
          permission == gps.LocationPermission.deniedForever) {
        throw StateError('Location permission is required.');
      }

      if (!mounted) return;

      setState(() {
        _following = true;
      });

      // If GPS is already running, use the last fix.
      if (_gpsSubscription != null) {
        final current = _lastPosition;

        if (current != null) {
          await _followPosition(
            CampusPoint(current.longitude, current.latitude),
          );
        }

        return;
      }

      _gpsSubscription =
          gps.Geolocator.getPositionStream(
            locationSettings: Platform.isAndroid
                ? gps.AndroidSettings(
                    accuracy: gps.LocationAccuracy.high,
                    distanceFilter: _gpsDistanceFilterMeters,
                    intervalDuration: _androidGpsInterval,
                  )
                : const gps.LocationSettings(
                    accuracy: gps.LocationAccuracy.high,
                    distanceFilter: _gpsDistanceFilterMeters,
                  ),
          ).listen(
            _onGpsFix,
            onError: (Object error) {
              _cowboyMotion.stop();
              _cowboyPlacement.value = null;

              if (mounted) {
                setState(() {
                  _following = false;
                  _lastPosition = null;
                  _locationMessage = 'GPS updates unavailable.';
                });
              }
            },
          );
    } catch (error) {
      if (mounted) {
        setState(() {
          _following = false;
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
  // STOP FOLLOWING
  // ==========================================

  void _stopFollowing() {
    if (_following && mounted) {
      setState(() {
        _following = false;
      });
    }
  }

  // ==========================================
  // RECEIVE LIVE GPS DATA
  // ==========================================

  void _onGpsFix(gps.Position position) {
    if (!mounted || !_ready) return;

    final campus = _geography;
    if (campus == null) return;

    final point = CampusPoint(position.longitude, position.latitude);

    // Do not display the Vaquero outside campus.
    if (!campus.contains(point)) {
      _cowboyMotion.stop();
      _cowboyPlacement.value = null;

      setState(() {
        _lastPosition = null;
        _following = false;
        _locationMessage = 'GPS position is outside the campus boundary.';
      });

      return;
    }

    // Update walking speed, direction, and animation.
    _cowboyMotion.accept(
      longitude: position.longitude,
      latitude: position.latitude,
      accuracy: position.accuracy,
      timestamp: position.timestamp,
      now: DateTime.now(),
      onCampus: true,
      measuredSpeed: position.speed,
      speedAccuracy: position.speedAccuracy,
    );

    setState(() {
      _lastPosition = position;
      _locationMessage = null;
    });

    // Project geographic position onto the screen.
    unawaited(_projectCowboy());

    if (_following) {
      unawaited(_followPosition(point));
    }
  }

  // ==========================================
  // GPS FOLLOW CAMERA
  // ==========================================

  Future<void> _followPosition(CampusPoint point) async {
    final map = _map;

    if (map == null || !_ready || !_following) {
      return;
    }

    try {
      await map.setCamera(
        CameraOptions(
          center: _point(point),
          zoom: _followZoom.clamp(_minZoom, _maxZoom).toDouble(),
          pitch: _cameraPitch,
          bearing: _cameraBearing,
        ),
      );

      unawaited(_projectCowboy());
    } catch (error) {
      debugPrint('GPS camera update failed: $error');
    }
  }

  // ==========================================
  // VAQUERO MAPBOX PROJECTION
  // ==========================================

  /// Converts real-world GPS coordinates
  /// into a position on the Flutter screen.
  Future<void> _projectCowboy() async {
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

        if (map == null || position == null || !_ready || !mounted) {
          break;
        }

        final point = CampusPoint(position.longitude, position.latitude);

        final pixel = await map.pixelForCoordinate(_point(point));

        final camera = await map.getCameraState();

        if (!mounted) break;

        if (pixel.x.isFinite && pixel.y.isFinite) {
          _cowboyPlacement.value = CowboyPlacement(
            Offset(pixel.x, pixel.y),
            camera.bearing,
            camera.pitch,
            camera.zoom,
          );
        } else {
          _cowboyPlacement.value = null;
        }
      } while (_projectionAgain);
    } catch (error) {
      debugPrint('Vaquero projection failed: $error');
    } finally {
      _projectionBusy = false;
    }
  }

  // ==========================================
  // SCREEN UI
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
          // MAPBOX CAMPUS MAP
          // ==================================
          if (_styleUri != null)
            MapWidget(
              key: ValueKey(_styleUri),
              styleUri: _styleUri!,

              viewport: CameraViewportState(
                center: Point(
                  coordinates: Position(_startLongitude, _startLatitude),
                ),
                zoom: _startZoom,
                pitch: _cameraPitch,
                bearing: _cameraBearing,
              ),

              // Manual panning stops GPS following.
              onScrollListener: (_) {
                _stopFollowing();
              },

              // Reproject Vaquero when camera moves.
              onCameraChangeListener: (_) {
                unawaited(_projectCowboy());
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

          // ==================================
          // ANIMATED VAQUERO GPS PLAYER
          // ==================================
          if (_ready)
            CowboySprite(motion: _cowboyMotion, placement: _cowboyPlacement),

          // ==================================
          // GPS AND ZOOM CONTROLS
          // ==================================
          if (_ready)
            Positioned(
              right: 12,
              bottom: 18,

              child: SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FloatingActionButton.small(
                      heroTag: 'campus-follow',
                      tooltip: _following ? 'GPS following' : 'Follow my GPS',

                      onPressed: _locating
                          ? null
                          : () {
                              if (_following) {
                                _stopFollowing();
                              } else {
                                unawaited(_beginGpsFollow());
                              }
                            },

                      child: Icon(
                        _following ? Icons.gps_fixed : Icons.my_location,
                      ),
                    ),

                    const SizedBox(height: 10),

                    FloatingActionButton.small(
                      heroTag: 'campus-zoom-in',
                      tooltip: 'Zoom in',
                      onPressed: () {
                        unawaited(_zoomBy(0.5));
                      },
                      child: const Icon(Icons.add),
                    ),

                    const SizedBox(height: 8),

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
          // GPS STATUS MESSAGE
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
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ),

          // ==================================
          // MAP LOADING / ERROR SCREEN
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
