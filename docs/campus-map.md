# Campus map

`assets/campus/boundary.geojson` defines the campus display extent. The local style uses campus-clipped buildings, routes and surfaces; no city basemap is imported. Camera bounds constrain navigation. Building heights are approximate display values.

Data source: https://api.openstreetmap.org/api/0.6/map?bbox=-98.188,26.297,-98.160,26.319 . Source identifiers and provenance are in `assets/campus/provenance.json`. The adapted geographic database is ODbL 1.0; retain `assets/campus/NOTICE.txt` and on-map attribution.

To regenerate the geometry, install Python and Shapely, then run `python tool/build_campus_data.py`. Keep the existing boundary file; the tool does not replace it.
