import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:geolocator/geolocator.dart' as gps;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size;

import '../map/campus_geography.dart';
import '../map/campus_style.dart';
import '../map/kitty_island.dart';
import '../widgets/kitty_island_cats.dart';
import '../player/cowboy_motion.dart';
import '../player/cowboy_travel.dart';
import '../player/latest_projection.dart';
import '../player/cowboy_sprite.dart';
import '../widgets/mapbox_configuration_notice.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  // ==========================================
  // CAMERA CONFIGURATION
  // ==========================================

  // UTRGV Student Union.
  static const double _startLatitude = 26.30546;
  static const double _startLongitude = -98.17525;

  static const double _startZoom = 18.5;
  static const double _followZoom = 19.0;

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

  final _kittyPlacement = ValueNotifier<List<Offset>?>(null);

  late final LatestProjection<List<Offset>> _kittyProjector;

  final _travel = CowboyTravel();

  late final Ticker _travelTicker;

  late final LatestProjection<CowboyPlacement> _projector;

  late final CameraViewportState _initialViewport;

  Duration? _previousTravelTick;

  Duration _lastProjectionTick = Duration.zero;
  Duration _lastFollowTick = Duration.zero;

  Timer? _expiry;

  bool _foreground = true;

  CampusPoint? _lastFollowCenter;
  DateTime? _latestFixTime;

  bool _followNeedsZoom = true;
  bool _followBusy = false;

  CampusPoint? _pendingFollowPoint;

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

    WidgetsBinding.instance.addObserver(this);

    _initialViewport = CameraViewportState(
      center: Point(coordinates: Position(_startLongitude, _startLatitude)),
      zoom: _startZoom,
      pitch: _cameraPitch,
      bearing: _cameraBearing,
    );

    // ========================================
    // KITTY ISLAND PROJECTION
    // ========================================

    _kittyProjector = LatestProjection<List<Offset>>(
      read: () async {
        final map = _map;

        if (map == null ||
            !_ready ||
            !_styleLoaded ||
            !_foreground ||
            _error != null) {
          return null;
        }

        final positions = <Offset>[];

        for (final point in KittyIsland.cats) {
          final pixel = await map.pixelForCoordinate(_point(point));

          if (!pixel.x.isFinite || !pixel.y.isFinite) {
            return null;
          }

          positions.add(Offset(pixel.x, pixel.y));
        }

        return positions;
      },

      apply: (positions) {
        if (mounted) {
          _kittyPlacement.value = positions;
        }
      },
    );

    // ========================================
    // VAQUERO PROJECTION
    // ========================================

    _projector = LatestProjection<CowboyPlacement>(
      read: _readCowboyProjection,

      apply: (placement) {
        if (mounted) {
          _cowboyPlacement.value = placement;
        }
      },
    );

    _travelTicker = createTicker(_advanceTravel);

    _expiry = Timer.periodic(const Duration(seconds: 1), (_) => _expireGps());

    if (hasMapboxConfiguration) {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    _expiry?.cancel();

    unawaited(_gpsSubscription?.cancel());

    _travelTicker.dispose();

    _kittyProjector.dispose();
    _kittyPlacement.dispose();

    _projector.dispose();
    _cowboyPlacement.dispose();

    super.dispose();
  }

  // ==========================================
  // APP LIFECYCLE
  // ==========================================

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _foreground = false;

      _syncKittyCats();
      _clearTravel();

      _cowboyMotion.stop();
      _lastPosition = null;
    } else if (state == AppLifecycleState.resumed) {
      _foreground = true;

      _syncKittyCats();
      _expireGps();
    }
  }

  // ==========================================
  // KITTY ISLAND
  // ==========================================

  void _syncKittyCats() {
    if (!_foreground || !_ready || _error != null) {
      _kittyProjector.cancel();
      _kittyPlacement.value = null;

      return;
    }

    unawaited(_kittyProjector.request(invalidate: true));
  }

  // ==========================================
  // CLEAR VAQUERO TRAVEL
  // ==========================================

  void _clearTravel() {
    _travel.clear();

    _travelTicker.stop();

    _previousTravelTick = null;
    _pendingFollowPoint = null;
    _lastFollowCenter = null;

    _projector.cancel();

    _cowboyPlacement.value = null;
  }

  // ==========================================
  // EXPIRE STALE GPS
  // ==========================================

  void _expireGps() {
    if (!mounted || !_foreground) {
      return;
    }

    final now = DateTime.now();
    final position = _lastPosition;

    if (position != null &&
        now.difference(position.timestamp).inMilliseconds > 6000) {
      _cowboyMotion.stop();
      _clearTravel();

      setState(() {
        _lastPosition = null;
        _locationMessage = 'GPS update is stale - waiting for location';
      });

      return;
    }

    final wasWalking = _cowboyMotion.walking;

    _cowboyMotion.expire(now);

    if (wasWalking != _cowboyMotion.walking) {
      unawaited(_projectCowboy());
    }
  }

  // ==========================================
  // SMOOTH VAQUERO MOVEMENT
  // ==========================================

  void _advanceTravel(Duration elapsed) {
    if (!_foreground || !_ready || _lastPosition == null) {
      _travelTicker.stop();
      _previousTravelTick = null;

      return;
    }

    final dt = _previousTravelTick == null
        ? 0.0
        : (elapsed - _previousTravelTick!).inMicroseconds / 1000000;

    _previousTravelTick = elapsed;

    final changed = _travel.advance(dt, contains: _geography!.contains);

    if (changed &&
        elapsed - _lastProjectionTick >= const Duration(milliseconds: 33)) {
      _lastProjectionTick = elapsed;

      unawaited(_projectCowboy());
    }

    if (changed &&
        _following &&
        elapsed - _lastFollowTick >= const Duration(milliseconds: 66)) {
      _lastFollowTick = elapsed;

      final point = _travel.position;

      if (point != null) {
        unawaited(_followPosition(point));
      }
    }

    if (!_travel.moving) {
      _travelTicker.stop();
      _previousTravelTick = null;

      unawaited(_projectCowboy());

      final point = _travel.position;

      if (_following && point != null) {
        unawaited(_followPosition(point));
      }
    }
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
  // LOAD CAMPUS MAP
  // ==========================================

  Future<void> _load() async {
    _kittyProjector.cancel();
    _kittyPlacement.value = null;

    _clearTravel();
    _cowboyMotion.stop();

    _lastPosition = null;

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

      // Vaquero replaces native GPS puck.
      await map.location.updateSettings(
        LocationComponentSettings(enabled: false),
      );

      await map.scaleBar.updateSettings(ScaleBarSettings(enabled: false));

      await map.setCamera(_openingCamera);

      if (!mounted) return;

      setState(() {
        _ready = true;
      });

      _syncKittyCats();

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
        _followNeedsZoom = true;
      });

      _expireGps();

      final currentPosition = _travel.position;

      if (currentPosition != null) {
        await _followPosition(currentPosition);
      }

      if (_gpsSubscription != null) {
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
              if (mounted) {
                _cowboyMotion.stop();
                _clearTravel();

                setState(() {
                  _following = false;
                  _lastPosition = null;
                  _locationMessage = 'GPS updates unavailable.';
                });
              }

              debugPrint('GPS stream error: $error');
            },

            onDone: () {
              _gpsSubscription = null;

              if (mounted) {
                _cowboyMotion.stop();
                _clearTravel();

                setState(() {
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
  // STOP GPS FOLLOWING
  // ==========================================

  void _stopFollowing() {
    _pendingFollowPoint = null;

    if (_following && mounted) {
      setState(() {
        _following = false;
      });
    }
  }

  // ==========================================
  // RECEIVE GPS UPDATES
  // ==========================================

  void _onGpsFix(gps.Position position) {
    if (!mounted || !_ready || !_foreground) {
      return;
    }

    final now = DateTime.now();

    if (_latestFixTime != null &&
        !position.timestamp.isAfter(_latestFixTime!)) {
      return;
    }

    final age = now.difference(position.timestamp).inMilliseconds;

    if (age > 6000 ||
        age < -2000 ||
        !position.accuracy.isFinite ||
        position.accuracy < 0 ||
        position.accuracy > 40 ||
        !position.latitude.isFinite ||
        !position.longitude.isFinite ||
        position.latitude.abs() > 90 ||
        position.longitude.abs() > 180) {
      _cowboyMotion.stop();
      _clearTravel();

      setState(() {
        _lastPosition = null;

        _locationMessage = 'Waiting for a fresh, accurate GPS position.';
      });

      return;
    }

    _latestFixTime = position.timestamp;

    final campus = _geography;
    if (campus == null) return;

    final point = CampusPoint(position.longitude, position.latitude);

    // Hide Vaquero outside campus.
    if (!campus.contains(point)) {
      _cowboyMotion.stop();
      _clearTravel();

      setState(() {
        _lastPosition = null;
        _following = false;

        _locationMessage = 'GPS position is outside the campus boundary.';
      });

      return;
    }

    // Determine walking and direction.
    _cowboyMotion.accept(
      longitude: position.longitude,
      latitude: position.latitude,
      accuracy: position.accuracy,
      timestamp: position.timestamp,
      now: now,
      onCampus: true,

      measuredSpeed: position.hasSpeed ? position.speed : null,

      speedAccuracy: position.hasSpeedAccuracy ? position.speedAccuracy : null,
    );

    _lastPosition = position;

    if (_locationMessage != null) {
      setState(() {
        _locationMessage = null;
      });
    }

    // Feed smooth travel interpolation.
    _travel.accept(
      point,
      position.timestamp,
      accuracy: position.accuracy,
      walking: _cowboyMotion.walking,
    );

    if (_travel.moving && !_travelTicker.isActive) {
      _previousTravelTick = null;

      _lastProjectionTick = Duration.zero;

      _lastFollowTick = Duration.zero;

      _travelTicker.start();
    }

    unawaited(_projector.request(invalidate: true));

    if (_following && _travel.position != null) {
      unawaited(_followPosition(_travel.position!));
    }
  }

  // ==========================================
  // GPS FOLLOW CAMERA
  // ==========================================

  Future<void> _followPosition(CampusPoint point) async {
    if (!_ready || !_following || !_foreground) {
      return;
    }

    _pendingFollowPoint = point;

    if (_followBusy) return;

    _followBusy = true;

    try {
      while (_pendingFollowPoint != null &&
          _following &&
          _ready &&
          mounted &&
          _foreground) {
        final next = _pendingFollowPoint;

        _pendingFollowPoint = null;

        final map = _map;

        if (map == null || next == null) {
          break;
        }

        final useFollowZoom = _followNeedsZoom;

        if (!useFollowZoom &&
            _lastFollowCenter != null &&
            CampusGeography.distance(_lastFollowCenter!, next) < 0.02) {
          continue;
        }

        _followNeedsZoom = false;
        _lastFollowCenter = next;

        await map.setCamera(
          CameraOptions(
            center: _point(_geography!.clampCameraCenter(next)),

            zoom: useFollowZoom
                ? _followZoom.clamp(_minZoom, _maxZoom).toDouble()
                : null,

            pitch: useFollowZoom ? _cameraPitch : null,

            bearing: useFollowZoom ? _cameraBearing : null,
          ),
        );

        unawaited(_projector.request(invalidate: true));
      }
    } catch (error) {
      debugPrint('GPS camera follow failed: $error');
    } finally {
      _followBusy = false;
    }
  }

  // ==========================================
  // VAQUERO SCREEN PROJECTION
  // ==========================================

  Future<void> _projectCowboy() {
    return _projector.request();
  }

  /// Converts the Vaquero's geographic position
  /// into Flutter screen coordinates.
  ///
  /// Rejects invalid and off-screen positions.
  /// Logs coordinates to help diagnose
  /// top-left-corner rendering issues.
  Future<CowboyPlacement?> _readCowboyProjection() async {
    final map = _map;
    final position = _travel.position;

    if (map == null ||
        position == null ||
        !_ready ||
        !mounted ||
        !_foreground ||
        _lastPosition == null) {
      return null;
    }

    try {
      final camera = await map.getCameraState();

      final pixel = await map.pixelForCoordinate(_point(position));

      if (!mounted) return null;

      final size = context.size;

      if (size == null || size.width <= 0 || size.height <= 0) {
        return null;
      }

      final x = pixel.x.toDouble();
      final y = pixel.y.toDouble();

      debugPrint(
        'VAQUERO POSITION: '
        'x=$x y=$y '
        'screen=${size.width}x${size.height}',
      );

      // Reject non-finite coordinates.
      if (!x.isFinite || !y.isFinite) {
        debugPrint('VAQUERO: Invalid screen coordinates');
        return null;
      }

      // Detect Mapbox returning the origin.
      if (x == 0 && y == 0) {
        debugPrint('VAQUERO: Mapbox returned (0,0)');
        return null;
      }

      // Do not show Vaquero outside the
      // visible Mapbox viewport.
      if (x < 0 || y < 0 || x > size.width || y > size.height) {
        debugPrint('VAQUERO: Outside visible screen');

        return null;
      }

      return CowboyPlacement(
        Offset(x, y),
        camera.bearing,
        camera.pitch,
        camera.zoom,
      );
    } catch (error) {
      debugPrint('VAQUERO PROJECTION ERROR: $error');

      return null;
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
              viewport: _initialViewport,

              onCameraChangeListener: (_) {
                _syncKittyCats();

                unawaited(_projector.request(invalidate: true));
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

                  _syncKittyCats();
                }
              },
            ),

          // ==================================
          // KITTY ISLAND CATS
          // ==================================
          Positioned.fill(
            child: ValueListenableBuilder<List<Offset>?>(
              valueListenable: _kittyPlacement,

              builder: (_, positions, _) {
                if (positions == null) {
                  return const SizedBox.shrink();
                }

                return KittyIslandCats(positions: positions);
              },
            ),
          ),

          // ==================================
          // ANIMATED VAQUERO
          // ==================================
          if (_ready)
            CowboySprite(motion: _cowboyMotion, placement: _cowboyPlacement),

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
                    // GPS-follow button.
                    FloatingActionButton.small(
                      heroTag: 'campus-follow',

                      tooltip: _following
                          ? 'Stop GPS following'
                          : 'Follow my GPS',

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
          // LOADING AND ERROR
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
