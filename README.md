# UTRGV-GO

Flutter app shell, Supabase accounts with .edu validation, and a campus-only Edinburg map.

Copy `app.config.example.json` to `app.config.local.json` and fill in the project values.

```sh
flutter pub get
flutter run --dart-define-from-file=app.config.local.json
```

Supabase: email confirmation off, password minimum 8. Do not replay the included migration on the already-configured project. Geographic attribution: `assets/campus/NOTICE.txt`.
