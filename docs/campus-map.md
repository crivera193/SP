# Campus map

`assets/campus/boundary.geojson` defines the campus display extent. The local style uses campus-clipped buildings, routes and surfaces; no city basemap is imported. Camera bounds constrain navigation. Building heights are approximate display values.

Data source: https://api.openstreetmap.org/api/0.6/map?bbox=-98.188,26.297,-98.160,26.319 . Source identifiers and provenance are in `assets/campus/provenance.json`. The adapted geographic database is ODbL 1.0; retain `assets/campus/NOTICE.txt` and on-map attribution.

To regenerate the geometry, install Python and Shapely, then run `python tool/build_campus_data.py`. Keep the existing boundary file; the tool does not replace it.


## GPS cowboy smoothing — October 26, 2026

SP adapts the UTRGV-GOTest `025d025` map integration while retaining its own
map, building labels, account configuration and existing camera-follow repair.
`CowboyTravel` now receives accepted fresh campus fixes; a vsync ticker advances
the cosmetic display position, with projection requests at most every 33 ms and
follow requests at most every 66 ms. GPS remains the source of geographic travel;
interpolation never predicts a route or grants gameplay eligibility.

The opening viewport is retained across widget rebuilds. Follow updates are
serialized and apply the follow zoom only on entry. `LatestProjection` rejects
replies invalidated by a newer GPS fix, camera event, reload or visibility loss.
Walking evidence expires periodically. Fixes older than six seconds, inaccurate
fixes, stream errors, campus exits and app suspension clear cosmetic travel and
pending projection work. Resume requires a new fix.

The existing atlases, persistent walk clock and above-building overlay rendering
are unchanged. Request budgets are not measured device FPS. Use
`flutter test test/cowboy_travel_test.dart` for the inherited synthetic travel,
cadence, facing and late-projection checks. Outdoor GPS and iOS need separate
validation. Local emulator verification uses an ignored map-only entrypoint and
a separate `com.example.campus_app.spverify` package, preserving the normal app.

Validation for this change: scoped Flutter analysis passed, all five inherited
travel/projection tests passed, and the Android debug verification build passed.
The APK's embedded changed map source/helpers and cowboy assets matched the
checkout. The preview emulator stopped answering Android shell commands during
the in-place test installation; the waiting installer was canceled. Installation
completion and smoothness of this revision are not visually verified.


## Kitty Island cats — October 26, 2026

SP reuses only UTRGV-GOTest's three bundled Lottie cats, Kitty Island positions
and decorative widget. The existing source-defined courtyard catalog is retained
from that implementation; this transfer does not create or alter live game-point
configuration. Cats are visible when their map positions enter the viewport,
independently of GPS, and their projection follows camera changes. Backgrounding,
map reload/errors and disposal hide/stop the overlays. They do not intercept map
input; reduced-motion preferences select still frames. The source animation has
a 1.28-second loop; orange/gray are color-only derivatives.

Assets, attribution and Lottie Simple License are under
`assets/animations/kitty-island/`. The palette regeneration tool is
`tool/create_kitty_variants.py`. No other creature artwork, proximity gates,
Supabase data or gameplay features are imported. `test/kitty_island_test.dart`
checks decoding, frame changes and input pass-through.

Validation: scoped Flutter analysis is clean; all six SP tests pass, including
actual Lottie decoding, frame differences and touch pass-through. Inspected the
full 432x960 widget-rendered cat view. Android debug build passed, and packaged
cat assets/source matched the checkout. Native map placement remains unverified
because the preview emulator is still not answering Android shell commands; no
new install was attempted. Dependency resolution uses Flutter 3.47.7's SDK pins.


## Local GPS drift/idle revision — pending owner test

October 26, 2026, local changes on SP base `1f905f8`; not committed or pushed.
The existing motion detector now checks short-window progression and valid speed
uncertainty. Idle fixes hold cosmetic travel; isolated distant fixes wait for a
consistent reacquisition cluster. A stale/poor fix pauses animation and retains
the last accepted display position with a visible uncertainty message, while
clearing the current-fix field. Background/campus-exit clearing remains intact.
No additional location providers, sensors, permissions or filter packages added.

Validation: all 15 tests pass and scoped Flutter analysis is clean. New cases
cover stationary jitter, noisy stops, slow walking, a provider stuck at zero,
turns, isolated jumps, reacquisition and interrupted interpolation. The Android
debug verification APK matches the local source and unchanged cowboy assets,
SHA-256 `3a780659404083383c02d1921b7260ea4173c33835d95a97788fd4f70cb692d9`.
Installed in place to the separate `com.example.campus_app.spverify` preview on
UTRGV_GO_Preview/emulator-5554; account/login flow is bypassed by the ignored
map-only test entrypoint. The normal app and phone were not replaced.

Native checks observed: synthetic eastward 1.2 m/s walking and northward restart,
stationary jitter returning to visible idle, eight seconds of paused GPS delivery
showing last-known/idle with no current fix, recovery clearing the message, and
a one-second approximately 40 m outlier returning without changing display
position. Sustained repeated displaced fixes can reacquire, deliberately; this
is not proof against sustained biased GPS. Native gap capture is ignored
`tmp/gps-gap-fixed.png`. Outdoor phone accuracy and owner acceptance are pending.


### Lottie landmark arrivals — November 1, 2026 (local verification)

Adapted UTRGV-GOTest `lib/games/spot_proximity.dart` and its focused tests for
SP's existing decorative locations. Kitty Island is one stop for the three cats;
Monstera is a separate stop. Existing coordinates and Lottie artwork are reused.
Arrival shows a dismissible card only; no game, reward, combat, account or backend
change is included. These are local artwork arrival invitations, not new live
Supabase gameplay points. No new product-location coordinates were introduced.

The existing foreground GPS stream supplies raw fixes after the cowboy jump
filter. Cosmetic interpolation never grants arrival. Defaults retained from the
reference: 25 m entry, 40 m exit, at most 15 m reported uncertainty, at most 10 s
fix age, and 3 s of consistent entry/exit evidence. GPS loss or backgrounding
revokes eligibility; dismissal stays suppressed until confirmed departure.
Animations remain independent of proximity. SP's existing 6 s GPS expiry also
revokes eligibility before the proximity engine's 10 s maximum.

Validation: analysis clean, all 25 tests passed. Fresh Android map-only debug
verification build installed in place on UTRGV_GO_Preview/emulator-5554,
1080x2400, package com.example.campus_app.spverify. Native UI showed Kitty Island
and Monstera arrival cards with their existing artwork, Dismiss stayed suppressed
near Kitty Island, GPS delivery pause removed eligibility while retaining the
last-known cowboy, and returning after departure re-triggered Kitty Island.
GPS subscription was resumed after the test. Synthetic emulator coordinates only;
real phone GPS and authenticated app flow remain unverified for this change.
APK SHA-256: 36f396649de94ae20f6995a1e8f69c79e739526e4c7b501d46366e4594879bf6.
Source baseline b53308c plus the local arrival implementation; not pushed.


### Automatic foreground GPS startup — November 2, 2026 (local)

MapScreen now starts its existing Geolocator stream automatically after its first
frame, concurrently with campus/style loading. The newest early fix is buffered
until map preparation completes, then revalidated through the normal timestamp,
accuracy and campus checks. CowboySprite mounts during loading so its assets can
load concurrently, but remains inactive until map readiness. Initial following
centers on the accepted fix; the follow button controls the camera independently.
No tracking starts at the signed-out login screen and no background permission or
new package is introduced. This supersedes the previous manual-GPS-button startup.

GPS start/cancellation is serialized with generation guards against late callbacks.
Hidden/paused cancels collection once, clears pending fixes and proximity, and
resume checks services/permission before restarting without repeating permission
prompts. Explicit Retry GPS permits a new permission request. Missing location
shows an acquisition/status message rather than inventing a position. Rendering
and fix acquisition remain independent; immediate or exact GPS is not guaranteed.

Verification: all 25 existing tests passed, analysis clean, diff check clean.
Fresh Android x86_64 map-only debug preview installed in place on emulator-5554
(UTRGV_GO_Preview, 1080x2400). On a cold app launch with permission already granted,
location/following started without a button tap; a projected cowboy placement was
observed by 6.92 s from launch and visually confirmed at Kitty Island. The native
continuous synthetic walk/stop check passed. Background inspection showed no GPS
subscription and no proximity eligibility; foreground return automatically
restored GPS and cowboy visibility. Camera-follow-off interaction was not verified
because concurrent owner input prevented the attempted click. First-time/denied
permission, disabled services and iOS runtime behavior remain unverified.

The universal and x64 updates initially hit emulator storage limits. Android cache
trim and removal of only SP preview's disposable hot-reload kernel/snapshot files
allowed the x64 in-place update; no app data was cleared or app uninstalled.
Installed APK SHA-256 matched the fresh local artifact:
218524fee6b503e79536288c783d4e71cc3a15ad70f89b31bdff9d1dac0145d8.
Source baseline ca51f32 plus local startup changes. Not committed or pushed.

Launcher confusion was also resolved: current SP Map Verification is pinned in
the lower-right dock instead of a changing suggested-app slot. The older UTRGV-GO
shortcut is separately labeled on the home grid above YouTube. Both shortcuts were
opened and their foreground package identities checked; neither app was removed.


### Independent position correction and stop detection — November 2, 2026 (local)

Supersedes the earlier idle-coordinate freeze. CowboyTravel no longer accepts a
walking flag: accepted GPS coordinates retarget its bounded, non-extrapolating
interpolation independently of gait. MapScreen no longer cancels interpolation
when the motion state becomes idle. GPS loss still explicitly holds the cosmetic
last-known position; freshness and proximity rules remain separate.

Motion uses one completed observation window instead of adding a stationary timer
after that window. Retaining at least three fixes supports irregular/sparse GPS
updates. Walking entry requires accumulated displacement plus independent moving
fixes; continuing a walk uses a lower speed threshold to tolerate uneven slow
fixes. A confident speed-based stop additionally requires recent agreement with
position-derived movement and a position that stopped advancing. Reliable slow
speed is no longer classified in the stationary speed range. This preserves
stuck-zero-provider fallback without allowing one isolated correction or a small
jitter burst to establish walking.

Verification: all 36 tests passed, analysis clean and diff check clean. Tests
include accurate and missing speed, speed becoming stuck at zero, .35m/s walking
and restart, uneven/duplicate slow fixes, update cadence .7–3s, isolated outliers,
idle position correction, interpolation completion, and the native jitter replay.
An intermediate native test exposed a slow-restart failure and a later trace
exposed a brief jitter restart; both were repaired before the final pass and
covered by explicit regressions. Passing an earlier build was not treated as
verification of these later changes.

Final native verification used the freshly built x86_64 map-only debug preview on
UTRGV_GO_Preview/emulator-5554 (1080x2400), with synthetic continuous movement.
The same walk/stop/resume replay used for the baseline measured legs becoming idle
about 1.19s after the first stationary input for the steady stop (baseline 3.00s),
and 1.41s for the small-jitter stop (baseline 2.29s). Whole-interval assertions
confirmed idle gait did not restart during either stop. Maximum cosmetic travel
after the stop command was .21m and .81m respectively; final displayed coordinates
matched received coordinates in both cases. These delays include provider delivery
and VM sampling, not a guarantee about physical human stopping time. Jitter can
still cause small position corrections while the legs are idle.

Native .35m/s walking remained active at 8/16/20s, stopped, restarted, and stopped
again successfully. Automatic GPS startup and existing artwork were visible in
the preview. Real phone GPS, first-time permissions, authenticated app flow and
iOS runtime were not exercised in this pass. No new motion sensor dependency or
permission was added. Source baseline 4e1561c plus these local changes; not pushed.
Installed APK SHA-256 matched the fresh artifact:
85e7460c0d7dfbc956c06270a8b081be702009517057eefa9e5917cef9e9aaba.
