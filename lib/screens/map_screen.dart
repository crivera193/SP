import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:geolocator/geolocator.dart' as gps;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../map/campus_geography.dart';
import '../map/campus_style.dart';
import '../map/campus_fix.dart';
import '../games/spot_proximity.dart';
import '../quizzes/quiz_models.dart';
import '../quizzes/quiz_repository.dart';
import '../quizzes/quiz_session.dart';
import '../quizzes/quiz_screen.dart';
import '../quizzes/quiz_markers.dart';
import '../player/cowboy_motion.dart';
import '../player/cowboy_travel.dart';
import '../player/latest_projection.dart';
import '../player/cowboy_sprite.dart';
import '../widgets/mapbox_configuration_notice.dart';
import '../nearby/nearby_controller.dart';
import '../nearby/ble_nearby_radio.dart';
import '../nearby/nearby_widgets.dart';
import '../nearby/verified_friend_book.dart';
import '../nearby/online_friend_directory.dart';
import '../nearby/offline_nearby_repository.dart';
import '../nearby/offline_friend_repository.dart';
import '../nearby/friend_directory_widgets.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  NearbyController? _nearby;
  VerifiedFriendBook? _friendBook;
  OnlineFriendDirectory? _friendDirectory;
  final _nearbyCamera = ValueNotifier<int>(0);
  NearbyController get _nearbyController {
    if (_nearby == null) _initFriends();
    return _nearby!;
  }

  void _initFriends() {
    if (_nearby != null) return;
    final client = Supabase.instance.client;
    final book = VerifiedFriendBook(client.auth.currentUser!.id);
    _friendBook = book;
    _friendDirectory = OnlineFriendDirectory(client, book);
    final local = OfflineNearbyRepository(book);
    final radio = BleNearbyRadio(
      identity: () => book.selfCode,
      onIdentity: local.identify,
    );
    _nearby = NearbyController(
      local,
      radio,
      friendRepository: OfflineFriendRepository(local),
      friendWire: radio.friendWire,
      localPosition: local.encodePosition,
      onPosition: (peer, fix) {
        local.receivePosition(peer, fix);
        unawaited(_nearby?.refresh());
      },
    );
    book.addListener(_friendsChanged);
    // Ordinary account bootstrap. No Bluetooth method can invoke this sync.
    unawaited(
      book.load().then((_) async {
        if (mounted) await _friendDirectory!.refresh();
      }),
    );
  }

  void _friendsChanged() {
    if (!mounted) return;
    unawaited(_nearby?.friends?.refresh());
    setState(() {});
  }
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

  bool _following = true;
  bool _locating = false;

  gps.Position? _lastPosition;
  gps.Position? _pendingGps;
  Future<void> _gpsOperations = Future<void>.value();
  int _gpsGeneration = 0;
  StreamSubscription<gps.Position>? _gpsSubscription;

  late final QuizCatalog _quizzes;
  final _quizPlacement = ValueNotifier<Map<String, Offset>?>(null);
  late final LatestProjection<Map<String, Offset>> _quizProjector;
  final _proximity = SpotProximity(const []);
  bool _quizOpen = false;

  Set<String> _revealedSpots = const <String>{};

  void _updateProximity(void Function() update) {
    final previousState = _proximity.state;
    final previousSpot = _proximity.selected?.id;
    final previousReveals = _revealedSpots;
    update();
    final nextReveals = _proximity.revealedSpots(DateTime.now());
    _revealedSpots = nextReveals;
    final revealsChanged =
        previousReveals.length != nextReveals.length ||
        !previousReveals.containsAll(nextReveals);
    if (mounted &&
        (previousState != _proximity.state ||
            previousSpot != _proximity.selected?.id ||
            revealsChanged)) {
      setState(() {});
    }
  }

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

    _quizProjector = LatestProjection<Map<String, Offset>>(
      read: () async {
        final map = _map;
        if (map == null ||
            !_ready ||
            !_styleLoaded ||
            !_foreground ||
            _error != null) {
          return null;
        }
        final points = _quizzes.points;
        final coordinates = <String, CampusPoint>{
          for (final p in points) p.id: p.point,
          for (final p in points)
            for (var i = 0; i < p.markerPoints.length; i++)
              '${p.id}#$i': p.markerPoints[i],
        };
        final pixels = await map.pixelsForCoordinates(
          coordinates.values.map(_point).toList(),
        );
        final ids = coordinates.keys.toList();
        return {
          for (var i = 0; i < ids.length && i < pixels.length; i++)
            if (pixels[i] case final ScreenCoordinate pixel)
              if (pixel.x.isFinite && pixel.y.isFinite)
                ids[i]: Offset(pixel.x, pixel.y),
        };
      },
      apply: (value) {
        if (mounted) _quizPlacement.value = value;
      },
    );

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
      _quizzes = QuizCatalog(SupabaseQuizRepository(Supabase.instance.client));
      _quizzes.addListener(_quizCatalogChanged);
      _initFriends();
      unawaited(_quizzes.load());
      unawaited(_load());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _foreground) unawaited(_startGps(allowPrompt: true));
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _nearby?.dispose();
    _friendBook?.removeListener(_friendsChanged);
    _friendDirectory?.dispose();
    _friendBook?.dispose();
    _nearbyCamera.dispose();

    _expiry?.cancel();

    unawaited(_stopGps());

    _travelTicker.dispose();

    if (hasMapboxConfiguration) {
      _quizzes.removeListener(_quizCatalogChanged);
      _quizzes.dispose();
    }
    _quizProjector.dispose();
    _quizPlacement.dispose();

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
      if (!_foreground) return;
      _foreground = false;
      if (hasMapboxConfiguration) _quizzes.setActive(false);
      _pendingGps = null;
      unawaited(_stopGps());
      _updateProximity(_proximity.unavailable);

      _syncQuizLocations();
      _clearTravel();

      _cowboyMotion.stop();
      _lastPosition = null;
    } else if (state == AppLifecycleState.resumed) {
      if (_foreground) return;
      _foreground = true;
      if (hasMapboxConfiguration) _quizzes.setActive(true);
      if (hasMapboxConfiguration) unawaited(_startGps());

      _syncQuizLocations();
      _expireGps();
    }
  }

  // ==========================================
  // KITTY ISLAND
  // ==========================================

  void _syncQuizLocations() {
    if (!_foreground || !_ready || _error != null) {
      _quizProjector.cancel();
      _quizPlacement.value = null;
      return;
    }
    unawaited(_quizProjector.request(invalidate: true));
  }

  void _quizCatalogChanged() {
    if (!mounted) return;
    _updateProximity(
      () => _proximity.replaceSpots(_quizzes.points, DateTime.now()),
    );
    setState(() {});
    _syncQuizLocations();
  }

  String? _quizReason(String id) {
    final point = _quizzes.find(id);
    if (point == null) return 'This quiz location is unavailable.';
    if (!_foreground) return 'Return to SP to answer.';
    if (_quizzes.error != null) return _quizzes.error;
    return _proximity.attackReason(point, DateTime.now());
  }

  Future<void> _openQuiz(QuizLocation point) async {
    if (_quizOpen) return;
    _quizOpen = true;
    final session = QuizSession(
      _quizzes,
      point.id,
      () => _proximity.currentFix,
      () => _quizReason(point.id),
    );
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => QuizScreen(session: session)),
      );
    } finally {
      session.dispose();
      _quizOpen = false;
      if (mounted) {
        _updateProximity(_proximity.dismiss);
        unawaited(_quizzes.load());
      }
    }
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

  // Visibility is independent of freshness: retain only the cosmetic last
  // accepted position. _lastPosition is cleared so it is not a current fix.
  void _holdTravel(String message) {
    _nearby?.updatePosition(null);
    _updateProximity(_proximity.unavailable);
    _cowboyMotion.stop();
    _travel.pause();
    _travelTicker.stop();
    _previousTravelTick = null;
    _pendingFollowPoint = null;
    _projector.cancel();
    setState(() {
      _lastPosition = null;
      _locationMessage = message;
    });
    unawaited(_projectCowboy());
  }

  void _expireGps() {
    if (!mounted || !_foreground) {
      return;
    }

    final now = DateTime.now();
    _updateProximity(() => _proximity.refresh(now));
    final position = _lastPosition;

    if (position != null &&
        now.difference(position.timestamp).inMilliseconds > 6000) {
      _holdTravel('Waiting for GPS - showing last known position');

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
    _updateProximity(_proximity.unavailable);
    _quizProjector.cancel();
    _quizPlacement.value = null;

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

      _syncQuizLocations();

      final pending = _pendingGps;
      _pendingGps = null;
      if (pending != null) _onGpsFix(pending);
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

  Future<void> _queueGps(Future<void> Function() operation) {
    // Cancellation completes before a new stream starts, including rapid resume.
    final next = _gpsOperations.then((_) => operation());
    _gpsOperations = next.catchError((Object error) {
      debugPrint('GPS lifecycle operation failed: $error');
    });
    return _gpsOperations;
  }

  Future<void> _stopGps() {
    _gpsGeneration++;
    return _queueGps(() async {
      final subscription = _gpsSubscription;
      _gpsSubscription = null;
      await subscription?.cancel();
    });
  }

  Future<void> _startGps({bool allowPrompt = false}) {
    final generation = _gpsGeneration;
    bool current() => mounted && _foreground && generation == _gpsGeneration;
    return _queueGps(() async {
      if (!current() || _gpsSubscription != null) return;
      setState(() {
        _locating = true;
        _locationMessage = 'Finding your location...';
      });
      try {
        final enabled = await gps.Geolocator.isLocationServiceEnabled();
        if (!current()) return;
        if (!enabled) {
          throw StateError('Enable location services on your device.');
        }
        var permission = await gps.Geolocator.checkPermission();
        if (!current()) return;
        if (permission == gps.LocationPermission.denied && allowPrompt) {
          permission = await gps.Geolocator.requestPermission();
          if (!current()) return;
        }
        if (permission == gps.LocationPermission.deniedForever) {
          throw StateError(
            'Location permission is blocked. Enable it in app settings.',
          );
        }
        if (permission == gps.LocationPermission.denied) {
          throw StateError('Location permission is required.');
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
              (position) {
                if (current()) _onGpsFix(position);
              },
              onError: (Object error) {
                if (!current()) return;
                _holdTravel('GPS unavailable - showing last known position');
                unawaited(_stopGps());
              },
              onDone: () {
                if (!current()) return;
                _gpsSubscription = null;
                _holdTravel('GPS unavailable - showing last known position');
              },
            );
      } catch (error) {
        if (current()) {
          setState(() {
            _locationMessage = error is StateError
                ? error.message
                : 'Could not start GPS.';
          });
        }
      } finally {
        if (mounted) setState(() => _locating = false);
      }
    });
  }

  Future<void> _retryGps() async {
    await _stopGps();
    if (mounted && _foreground) await _startGps(allowPrompt: true);
  }

  void _beginGpsFollow() {
    setState(() {
      _following = true;
      _followNeedsZoom = true;
    });
    final position = _travel.position;
    if (position != null) unawaited(_followPosition(position));
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
    if (!mounted || !_foreground) return;
    if (!_ready) {
      if (_pendingGps == null ||
          position.timestamp.isAfter(_pendingGps!.timestamp)) {
        _pendingGps = position;
      }
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
      _holdTravel('Waiting for accurate GPS - showing last known position');

      return;
    }

    _latestFixTime = position.timestamp;

    final campus = _geography;
    if (campus == null) return;

    final point = CampusPoint(position.longitude, position.latitude);

    // Hide Vaquero outside campus.
    if (!campus.contains(point)) {
      _nearby?.updatePosition(null);
      _updateProximity(_proximity.unavailable);
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
    _travel.accept(point, position.timestamp, accuracy: position.accuracy);

    if (_travel.awaitingReacquisition) {
      _holdTravel('Checking GPS position - showing last known position');
      return;
    }

    _nearby?.updatePosition(
      CampusFix(point, position.accuracy, position.timestamp),
    );

    _updateProximity(
      () => _proximity.accept(
        CampusFix(point, position.accuracy, position.timestamp),
        onCampus: true,
        now: now,
      ),
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
    if (!_ready || !_following || !_foreground || _quizOpen) {
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
        !_foreground) {
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

    final nearby = _ready ? _nearbyController : null;
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
                _nearbyCamera.value++;
                _syncQuizLocations();

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

                  _syncQuizLocations();
                }
              },
            ),

          Positioned.fill(
            child: ValueListenableBuilder<Map<String, Offset>?>(
              valueListenable: _quizPlacement,
              builder: (_, positions, _) => positions == null
                  ? const SizedBox.shrink()
                  : QuizMarkers(
                      locations: _quizzes.points,
                      positions: positions,
                      revealed: _revealedSpots,
                      onOpen: (point) => unawaited(_openQuiz(point)),
                    ),
            ),
          ),
          if (_ready &&
              (_quizzes.error != null ||
                  !_quizzes.loaded ||
                  _quizzes.points.isEmpty))
            Positioned(
              left: 12,
              right: 76,
              bottom: 100,
              child: SafeArea(child: QuizCatalogNotice(catalog: _quizzes)),
            ),

          // ANIMATED VAQUERO
          // ==================================
          CowboySprite(
            motion: _cowboyMotion,
            placement: _cowboyPlacement,
            active: _ready && _foreground,
          ),
          if (_ready && nearby != null)
            Positioned.fill(
              child: NearbyMapLayer(
                controller: nearby,
                map: _map,
                cameraChanges: _nearbyCamera,
                active: _foreground && _error == null,
              ),
            ),
          if (_ready)
            Positioned(
              left: 12,
              top: 12,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  NearbyButton(controller: nearby!),
                  const SizedBox(height: 8),
                  if (_friendDirectory != null)
                    FriendDirectoryButton(directory: _friendDirectory!),
                ],
              ),
            ),

          // ==================================
          // GPS AND ZOOM BUTTONS
          // ==================================
          if (_ready && _foreground && _proximity.state == SpotState.eligible)
            Positioned(
              left: 12,
              right: 76,
              bottom: 100,
              child: SafeArea(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _proximity.selected!.name,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const Text(
                          'You have arrived. Stop walking to answer a quiz.',
                        ),
                        FilledButton(
                          onPressed: () {
                            final point = _quizzes.find(
                              _proximity.selected!.id,
                            );
                            if (point != null) unawaited(_openQuiz(point));
                          },
                          child: const Text('Open quiz'),
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: () =>
                                _updateProximity(_proximity.dismiss),
                            child: const Text('Dismiss'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

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
                                _beginGpsFollow();
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

                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _locationMessage!,
                        style: const TextStyle(fontSize: 12),
                      ),
                      if (!_locating && _gpsSubscription == null)
                        TextButton(
                          onPressed: _retryGps,
                          child: const Text('Retry GPS'),
                        ),
                    ],
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
