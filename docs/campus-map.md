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
