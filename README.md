# UTRGV-GO

Flutter app shell, Supabase accounts with @utrgv.edu validation, and a campus-only Edinburg map.

Source repository: [crivera193/SP](https://github.com/crivera193/SP). Backend:
SProject_2.0 (`bsvcnndqvjizxgnxhxkd`). [Nearby players](docs/nearby-players.md)
uses Bluetooth encounters while both users opt in and keep the app active; GPS
only supplies their map positions. Physical Android/iPhone acceptance is pending.

[Permanent team selection](docs/team-selection.md) uses the SP-specific migration
applied to live Supabase on November 8, 2026. Do not replay it. The normal sign-in,
selection, cancel/save and restored membership flows were checked on Android.

```sh
flutter pub get
flutter run --dart-define-from-file=app.config.local.json
```

