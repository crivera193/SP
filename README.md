# UTRGV-GO

Flutter app shell, Supabase accounts with @utrgv.edu validation, and a campus-only Edinburg map.

Source repository: [crivera193/SP](https://github.com/crivera193/SP). Backend:
SProject_2.0 (`bsvcnndqvjizxgnxhxkd`). [Nearby players](docs/nearby-players.md)
uses Bluetooth encounters while both users opt in and keep the app active; GPS
only supplies their map positions. Physical Android/iPhone acceptance is pending.

[Permanent team selection](docs/team-selection.md) requires the new SP-specific
database migration **before deploying this app revision**. It is included and
locally tested; it has not been applied to live Supabase.

```sh
flutter pub get
flutter run --dart-define-from-file=app.config.local.json
```

