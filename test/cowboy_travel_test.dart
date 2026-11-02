import 'dart:async';
import 'package:campus_app/player/cowboy_motion.dart';
import 'package:campus_app/player/cowboy_playback.dart';
import 'package:campus_app/player/cowboy_travel.dart';
import 'package:campus_app/player/latest_projection.dart';
import 'package:campus_app/map/campus_geography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final epoch = DateTime.utc(2026, 1, 1);
  test(
    'SIMULATED replay of observed 4.3 m/s route: east, north, capped walk',
    () {
      final motion = CowboyMotion();
      for (var t = 0; t <= 4; t++) {
        final now = epoch.add(Duration(seconds: t));
        motion.accept(
          longitude: t * 4.3 / 111320,
          latitude: 0,
          accuracy: 5,
          timestamp: now,
          now: now,
          onCampus: true,
          measuredSpeed: 4.3,
          speedAccuracy: 0.5,
        );
      }
      expect(motion.walking, isTrue);
      expect(motion.heading, closeTo(90, 0.1));
      expect(motion.playbackRate, 1.35);
      final now = epoch.add(const Duration(seconds: 5));
      motion.accept(
        longitude: 4 * 4.3 / 111320,
        latitude: 4.3 / 111320,
        accuracy: 5,
        timestamp: now,
        now: now,
        onCampus: true,
        measuredSpeed: 4.3,
        speedAccuracy: 0.5,
      );
      expect(motion.heading, closeTo(0, 0.1));
      expect(motion.walking, isTrue);
    },
  );
  test(
    'SIMULATED cadence: 12–20m accuracy no longer expires walk evidence',
    () {
      for (final accuracy in [12.0, 20.0]) {
        final m = CowboyMotion();
        for (var t = 0; t <= 16; t++) {
          final now = epoch.add(Duration(seconds: t));
          m.expire(now); // The previous bug requires expiry between arrivals.
          m.accept(
            longitude: 0,
            latitude: t * 1.2 / 111320,
            accuracy: accuracy,
            timestamp: now,
            now: now,
            onCampus: true,
          );
          if (t >= 8) {
            expect(m.walking, isTrue, reason: 'accuracy $accuracy, sample $t');
          }
        }
        for (var t = 17; t <= 20; t++) {
          final now = epoch.add(Duration(seconds: t));
          m.accept(
            longitude: 0,
            latitude: 16 * 1.2 / 111320,
            accuracy: accuracy,
            timestamp: now,
            now: now,
            onCampus: true,
          );
        }
        expect(m.walking, isFalse);
      }
    },
  );
  test(
    'SIMULATED display: continuous retarget, bounded lag and no prediction',
    () {
      final travel = CowboyTravel();
      travel.accept(
        const CampusPoint(0, 0),
        epoch,
        accuracy: 12,
        walking: false,
      );
      final target = CampusPoint(0, 1.2 / 111320);
      travel.accept(
        target,
        epoch.add(const Duration(seconds: 1)),
        accuracy: 12,
        walking: true,
      );
      var last = travel.position!;
      for (var f = 0; f < 15; f++) {
        travel.advance(1 / 60);
        expect(
          CampusGeography.distance(last, travel.position!),
          lessThan(0.13),
        );
        last = travel.position!;
      }
      final current = travel.position!;
      final next = CampusPoint(0, 2.4 / 111320);
      travel.accept(
        next,
        epoch.add(const Duration(milliseconds: 1250)),
        accuracy: 12,
        walking: true,
      );
      expect(travel.position, same(current));
      for (var f = 0; f < 40; f++) {
        travel.advance(1 / 60);
      }
      expect(CampusGeography.distance(travel.position!, next), lessThan(0.01));
      for (var f = 0; f < 600; f++) {
        travel.advance(1 / 60);
      }
      expect(
        travel.position,
        same(next),
      ); // Never extrapolates a last velocity.
      expect(
        travel.accept(
          const CampusPoint(0, 0),
          epoch,
          accuracy: 3,
          walking: true,
        ),
        isFalse,
      );
      travel.clear();
      expect(travel.position, isNull);
    },
  );
  test('loop survives long frames and facing has a switching margin', () {
    final loop = CowboyPlayback(), facing = CowboyFacing();
    loop.advance(.3, walking: true, rate: 1);
    expect(loop.phase, closeTo(.225, 1e-9));
    expect(loop.frame, 2);
    final phase = loop.phase;
    expect(facing.direction(0, 0), 0);
    expect(facing.direction(23, 0), 0);
    expect(facing.direction(22, 0), 0);
    expect(facing.direction(30, 0), 1);
    expect(facing.direction(20, 0), 1);
    expect(facing.direction(15, 0), 0);
    expect(facing.pitch(45), 2);
    expect(facing.pitch(39), 2);
    expect(loop.phase, phase);
    loop.advance(0, walking: false, rate: 1);
    expect(loop.frame, 12);
    loop.dispose();
  });
  test(
    'late projection discarded, coalesced queue reads latest only',
    () async {
      var target = 1, reads = 0;
      final completions = <Completer<int?>>[],
          applied = <int?>[],
          inputs = <int>[];
      final projector = LatestProjection<int>(
        read: () {
          reads++;
          inputs.add(target);
          final c = Completer<int?>();
          completions.add(c);
          return c.future;
        },
        apply: applied.add,
      );
      final done = projector.request();
      target = 2;
      unawaited(projector.request(invalidate: true));
      target = 3;
      unawaited(projector.request());
      expect(reads, 1);
      completions[0].complete(1);
      await Future<void>.delayed(Duration.zero);
      expect(applied, isEmpty);
      expect(inputs, [1, 3]);
      completions[1].complete(3);
      await done;
      expect(applied, [3]);
      final pending = projector.request();
      projector.dispose();
      completions[2].complete(3);
      await pending;
      expect(applied, [3]);
    },
  );
  void sample(
    CowboyMotion motion,
    int second,
    double east, {
    double north = 0,
    double? providerSpeed,
    double? providerAccuracy,
  }) {
    final now = epoch.add(Duration(seconds: second));
    motion.expire(now);
    motion.accept(
      longitude: east / 111320,
      latitude: north / 111320,
      accuracy: 12,
      timestamp: now,
      now: now,
      onCampus: true,
      measuredSpeed: providerSpeed,
      speedAccuracy: providerAccuracy,
    );
  }

  test(
    'stationary GPS jitter with reliable zero speed never starts walking',
    () {
      final motion = CowboyMotion();
      const noise = [0.0, 2.0, -1.5, 1.0, -2.0, 0.5];
      for (var t = 0; t < 30; t++) {
        sample(
          motion,
          t,
          noise[t % noise.length],
          providerSpeed: 0,
          providerAccuracy: 0.15,
        );
        expect(motion.walking, isFalse, reason: 'stationary sample $t');
      }
    },
  );

  test('walk then noisy stop without speed settles and stays idle', () {
    final motion = CowboyMotion();
    for (var t = 0; t <= 12; t++) {
      sample(motion, t, t * 1.2);
    }
    expect(motion.walking, isTrue);
    const noise = [0.5, -0.7, 0.8, -0.6, 0.2, 0.0];
    for (var t = 13; t <= 36; t++) {
      sample(motion, t, 14.4 + noise[(t - 13) % noise.length]);
      if (t >= 20) expect(motion.walking, isFalse, reason: 'noisy stop $t');
    }
    for (var t = 37; t <= 46; t++) {
      sample(motion, t, 14.4 + (t - 36) * 1.2);
    }
    expect(motion.walking, isTrue);
  });

  test('slow walking without provider speed is not frozen as stationary', () {
    final motion = CowboyMotion();
    for (var t = 0; t <= 20; t++) {
      sample(motion, t, t * 0.35);
      if (t >= 12) expect(motion.walking, isTrue, reason: 'slow sample $t');
    }
  });

  test(
    'a provider stuck at zero does not veto substantial sustained travel',
    () {
      final motion = CowboyMotion();
      for (var t = 0; t <= 18; t++) {
        sample(motion, t, t * 1.2, providerSpeed: 0, providerAccuracy: 0.1);
      }
      expect(motion.walking, isTrue);
    },
  );

  test('normal walk and courtyard turn retain movement', () {
    final motion = CowboyMotion();
    for (var t = 0; t <= 10; t++) {
      sample(motion, t, t * 1.2);
    }
    for (var t = 11; t <= 18; t++) {
      sample(motion, t, 12, north: (t - 10) * 1.2);
    }
    expect(motion.walking, isTrue);
    expect(motion.heading, closeTo(0, 1));
  });

  test('idle location jitter does not produce cosmetic travel', () {
    final travel = CowboyTravel();
    const origin = CampusPoint(0, 0);
    travel.accept(origin, epoch, accuracy: 20, walking: false);
    for (var t = 1; t <= 20; t++) {
      travel.accept(
        CampusPoint((t.isEven ? 2.0 : -2.0) / 111320, 0),
        epoch.add(Duration(seconds: t)),
        accuracy: 20,
        walking: false,
      );
      travel.advance(1);
      expect(travel.position, same(origin));
      expect(travel.moving, isFalse);
    }
  });

  test('one large outlier is held and returning fixes recover normally', () {
    final travel = CowboyTravel();
    const origin = CampusPoint(0, 0);
    travel.accept(origin, epoch, accuracy: 5, walking: false);
    expect(
      travel.accept(
        CampusPoint(40 / 111320, 0),
        epoch.add(const Duration(seconds: 1)),
        accuracy: 5,
        walking: true,
      ),
      isFalse,
    );
    expect(travel.awaitingReacquisition, isTrue);
    expect(travel.position, same(origin));
    travel.accept(
      CampusPoint(1.2 / 111320, 0),
      epoch.add(const Duration(seconds: 2)),
      accuracy: 5,
      walking: true,
    );
    travel.advance(1);
    expect(travel.awaitingReacquisition, isFalse);
    expect(
      CampusGeography.distance(origin, travel.position!),
      closeTo(1.2, .01),
    );
  });

  test(
    'consistent new location can reacquire without permanently freezing',
    () {
      final travel = CowboyTravel();
      const origin = CampusPoint(0, 0);
      final relocated = CampusPoint(40 / 111320, 0);
      travel.accept(origin, epoch, accuracy: 5, walking: false);
      for (var t = 10; t <= 12; t++) {
        final accepted = travel.accept(
          relocated,
          epoch.add(Duration(seconds: t)),
          accuracy: 5,
          walking: false,
        );
        expect(accepted, t == 12);
        if (t < 12) expect(travel.position, same(origin));
      }
      expect(travel.position, same(relocated));
      expect(travel.awaitingReacquisition, isFalse);
    },
  );

  test(
    'stopping cancels unfinished interpolation without clearing position',
    () {
      final travel = CowboyTravel();
      travel.accept(
        const CampusPoint(0, 0),
        epoch,
        accuracy: 5,
        walking: false,
      );
      travel.accept(
        CampusPoint(2 / 111320, 0),
        epoch.add(const Duration(seconds: 1)),
        accuracy: 5,
        walking: true,
      );
      travel.advance(.1);
      final stopped = travel.position;
      travel.pause();
      for (var i = 0; i < 100; i++) {
        travel.advance(.1);
      }
      expect(travel.position, same(stopped));
      expect(stopped, isNotNull);
      expect(travel.moving, isFalse);
    },
  );
}
