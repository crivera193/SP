# Permanent team selection in SP

Transferred from `crivera193/UTRGV-GOTest` main commit
`025d0255ec366a3f021a320f086f278eb619f416`, onto SP main
`ebf883025da51fed59bfb6875888ab03fde8ec9d`, November 8, 2026.
Only team onboarding, its neutral hat sprite and focused tests were reused.
No test-project accounts, profiles, combat rules, Bluetooth changes or backend
configuration were transferred.

After authentication, the account-keyed `TeamGate` reads the saved team before
mounting SP's existing map. Unassigned players inspect a floating hat or its named
button and explicitly confirm a permanent choice. Canceling writes nothing.
Assigned players skip selection and can inspect their team through the app bar.
Signing out discards the account's nested navigator, including dialogs. SP keeps
its existing `@utrgv.edu` policy, auth storage, map, GPS and Bluetooth code.

`lib/teams/` contains presentation, membership state and the Supabase adapter.
The adapter calls `sp_teams_read()` and `sp_teams_choose(requested_team)`;
it never sends an account ID to an assignment function. Errors block entry with
Retry/Sign out rather than inventing a local membership. Saves reread the server
first and reconcile lost responses. Late responses after disposal are ignored.

## Backend deployment prerequisite

The migration `supabase/migrations/20261108010000_sp_permanent_teams.sql` is
**included as source and locally tested, not applied to live Supabase**.
Before deploying this app revision, inspect SP project
`bsvcnndqvjizxgnxhxkd` (SProject_2.0) for conflicting objects and apply this exact
migration through its authorized deployment workflow. Do not replay it or use
UTRGV-GOTest's backend. Without these RPCs the app intentionally shows the team
check error after sign-in; it cannot enter the map until deployment is complete.
Source push does not deploy this schema or update installed apps.

The migration adds only the isolated `sp_teams` schema and two namespaced public
RPCs. It does not alter existing signup functions or import another project's
profile schema. Functions check the actual authenticated Auth row for an exact
`@utrgv.edu` domain. Direct client schema/table access and anonymous RPC execution
are denied. An account lock plus unique membership key arbitrate concurrent
choices; retries return the original winner. Membership updates/deletes are
blocked, including privileged accidental writes. As in the source feature,
membership deliberately restricts Auth account deletion; any future account
deletion feature needs an explicit server maintenance design.

Editable `sp_teams.catalog` rows provide stable IDs, names, descriptions, colors,
ordering and availability. The initial three teams match the original selector.
Add or edit rows through trusted administration; clients read the catalog on
entry/retry and before saving, without rebuilding. Disable teams instead of
deleting referenced IDs. Disabled teams remain visible to their existing members
but cannot be newly selected. An empty catalog blocks new choices explicitly.
More teams scroll horizontally with readable labels and matching hat hit targets.
There is no enum or product-data fallback in the app.

## Verification

Flutter 3.47.7 / Dart 3.13.5, Flame 1.38.2. Commands from this checkout:

```powershell
flutter analyze --no-pub lib test
flutter test --no-pub
node tool/check_teams_sql.mjs
```

The SQL harness uses the existing ignored PGlite installation under
`tmp/nearby-sql/`; install it with
`npm install --prefix tmp/nearby-sql --no-save --package-lock=false @electric-sql/pglite`
if absent. It uses synthetic users in a local PostgreSQL instance, never live
Supabase. It checks account eligibility, privacy/access denial, immutable choice,
retries, catalog add/rename/recolor/reorder/disable and retained timestamps.
The real two-session concurrency scenario is not revalidated against live SP.

All 65 unit/widget tests passed. Team checks include actual Flame loading,
cancel/confirmation, duplicate saves, uncertain responses, restored membership,
account-switch route disposal, failed/empty catalog states, an added fourth team,
small phone/landscape/large text, the actual SP app-bar team dialog and dialog/lifecycle pausing. The existing Kitty
Island test now verifies upstream's interactive cat card plus surrounding map
input, replacing its outdated expectation that cat taps pass through.

Actual current widget renders at 390×844, DPR 1 were inspected for three teams,
the confirmation dialog and the scrolled four-team state: all show the shared
hat, matching colored lights and readable labels/actions. Recreate with
`flutter test --no-pub test/team_onboarding_test.dart --dart-define=CAPTURE_TEAM_REVIEW=true --update-goldens`.
Captures are ignored under `output/team-review/`; these are widget renders,
not native phone screenshots or owner acceptance.

Android x86_64 debug integration uses the production `lib/main.dart` entrypoint
and the existing ignored Mapbox configuration; the final build passed. APK SHA-256:
`78c0d9b69fea449ae084b7ba5fe0d82865094e31adb82c998021d3c611bb0d7a`.
Existing Bluetooth/Mapbox Kotlin future-toolchain warnings remain. No install, live account choice,
backend mutation or physical-phone test is part of this source transfer. Current
iOS compilation and live SP onboarding/restart/two-device tests remain separate
deployment verification. Existing Bluetooth device evidence does not verify
this new onboarding revision.
