# UTRGV-GO

Flutter app shell, login/signup, .edu validation and Supabase accounts.

Copy `app.config.example.json` to `app.config.local.json` and fill in the project values.

```sh
flutter pub get
flutter run --dart-define-from-file=app.config.local.json
```

Supabase: email confirmation off, minimum password length 8. The included account migration is already applied to the existing project; do not replay it there.
