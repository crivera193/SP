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
