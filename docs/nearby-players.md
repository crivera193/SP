# Nearby players in SP

SP is `crivera193/SP`. Backend: SProject_2.0, project `bsvcnndqvjizxgnxhxkd`.
UTRGV-GOTest is outside this feature's scope.

## Player experience

On the map, open **Nearby players**, then **Turn on**. Both players must enable it,
allow Bluetooth, keep SP active, and have internet access. Bluetooth establishes
encounters; GPS only supplies map coordinates for already discovered players.
GPS distance, landmark proximity and online-account lists never discover players.
An encountered player without a fresh accurate GPS fix is counted but has no marker.
Turn off stops advertising, scanning and sharing. Backgrounding, focus loss,
sign-out, Bluetooth failure and network failure clear the local discovered set.
Returning to the app requires a new session and new Bluetooth exchanges.

## Protocol and authority

`bluetooth_low_energy` 6.2.1 provides central and peripheral roles on Android/iOS.
Both phones advertise the fixed service `8c56b84b-4f58-47ba-ae42-39bcc8fe7001`.
The session-read characteristic ends in `7002`; challenge-write ends in `7003`.
Only the service UUID is advertised. No email, account JWT, device name or GPS
coordinates are broadcast. GATT values are 16-byte opaque UUIDs, fitting baseline
ATT payloads without MTU negotiation or fragmentation.

The central connects, reads the peer's current session token and asks Supabase for
a random one-use challenge bound to both live sessions. It writes that challenge
over GATT. Only the authenticated recipient can confirm it. A confirmed receipt
authorizes both users to read the other's temporary map position. Replaying a
receipt never renews it. A cached advertisement alone cannot renew an encounter.
One outgoing link runs at a time; incoming writes can independently establish the
bilateral encounter. Service/scan operations are serialized and lifecycle epochs
reject late callbacks. No pairing dialog or Bluetooth Classic socket is required.

This is proximity for ordinary app clients, not a cryptographic distance guarantee.
A modified client or BLE relay can falsify proximity. Bluetooth range varies by
phone/environment; it is not an exact meter radius. Crowded-campus capacity and
simultaneous central/peripheral behavior need physical-device measurement.

## Database and expiry

Migration `20261105010000_sp_bluetooth_nearby.sql` creates only `sp_nearby` and six
new public RPCs. The three new tables are `settings`, `sessions` and `rounds`.
Existing tables, accounts and the existing `restrict_utrgv_signup` function are
unchanged. No former-project schema/data is imported. The account policy remains
`@utrgv.edu`. The FK points from temporary sessions to accounts; deleting a session
cannot delete its account.

RLS and schema/table revocations deny direct client reads. Only authenticated
callers can execute the RPCs; ownership and eligible accounts are checked inside
them. Session tokens are never returned with map results. Public labels use a
session-specific random ID, not an account identifier.

Editable server settings, with validated bounds in both client and database:

| Setting | Initial value | Purpose |
| --- | --- | --- |
| enabled | true | Disable the feature server-side |
| heartbeat_s | 4 | Renew foreground activity and poll discovered positions |
| lease_s | 24 | Maximum server activity lease after a missed close |
| encounter_s | 18 | Maximum confirmed Bluetooth receipt lifetime |
| challenge_s | 8 | Maximum time to confirm a fresh challenge |
| fix_s | 6 | Maximum GPS fix age |
| max_accuracy_m | 40 | Maximum accepted reported GPS uncertainty |
| max_peers | 12 | Bounded session processing/display count |
| scan_s / pause_s | 20 / 5 | Scan windows and pauses |

Expiry is bounded, not instantaneous: a normal close removes the session; other
clients see that on their next poll. If a phone loses internet or is killed before
closing, the peer can remain until the receipt/lease expires. GPS positions expire
independently and normally sooner. Local display subtracts the full request round
trip from server deadlines. No background service or iOS Bluetooth background mode
extends sharing. Network is needed for server authorization and map-position reads;
Bluetooth alone is the discovery signal, not the entire data transport.

Cleanup DELETE statements affect only expired/closed rows in these new temporary
tables. REVOKE statements affect only the new schema and exact new RPC signatures.
They explain Supabase's generic destructive-query warning; they do not delete or
modify existing application tables. Cleanup runs during active opens/heartbeats;
expired rows can remain physically stored while nobody uses the feature, but are
ineligible for discovery. No scheduled cleanup job was added.

## Verification on November 6, 2026

- Chrome extension repaired by disabling/re-enabling the existing ChatGPT extension;
  all subsequent Supabase operations used extension control.
- Before applying, read-only checks returned no discovery schema/table/functions.
  An editor insertion error caused a SQL syntax failure; another read-only check
  confirmed no schema before the corrected transaction was submitted.
- Supabase reported success. Readback found three RLS-protected tables and six
  security-definer RPCs executable by authenticated, not anon. Existing signup
  function hash stayed `5d38f1062370e46ab70ea0a9be9a0f24`; public has zero tables.
  Evidence: ignored `output/nearby/backend-verified.png`.
- 48 Flutter tests passed, including 12 new checks for GPS/discovery separation,
  lifecycle races, stale responses/positions, permission/network failure, decoding
  and actual opt-in/off panel interactions. `flutter analyze --no-pub lib test`
  passed. Whole-folder analysis also sees pre-existing ignored `tmp/` probes.
- Android debug integration build succeeded with Flutter 3.47.7, the production
  `lib/main.dart` entrypoint and the established isolated `.spverify` preview
  application ID (x86_64). Bluetooth and SharedPreferences native registration
  are present. Original manifest/application ID were restored after the build.
  No app was installed and no physical-device runtime result is claimed.
- `node tool/check_nearby_sql.mjs` passed against local PostgreSQL (PGlite), with
  synthetic auth users. It exercises migration, ownership/access, bilateral receipt,
  replay, challenge/encounter/GPS expiry and GPS alone yielding no encounters.
  It is not a live multi-client or physical Bluetooth test. Setup the local harness
  with `npm install --prefix tmp/nearby-sql --no-save --package-lock=false @electric-sql/pglite`.

Remaining acceptance checks: current Xcode/iOS compilation; physical Android to
iPhone, Android to Android and iPhone to iPhone discovery; first-run permissions,
screen lock/background/force quit, Bluetooth off, internet interruption, resume,
sign-out/account switch, stale GPS and crowded-campus load. No connected Mac was
available and an Android emulator cannot prove BLE interoperability. Do not claim
the feature is device-verified until these checks are observed on current builds.

### Physical-phone update on November 6

SP source `7408a5e` was built and launched on both physical phones:

- Samsung SM-S948U1: release build 12050, separate package
  `com.example.campus_app.spverify`, label SP Bluetooth Test. Installed APK SHA-256
  matched `a14d9373e158e44c24b7a684d339c889cce52aa7d5a9d197265f6d58623a4fca`.
  The original testing app retained build 12049 and its October 23 update time.
- iPhone 13 Pro Max: Xcode Release build 3, bundle `com.example.campusApp`, original
  development team/profile verified, signature verification passed, in-place
  installation and launch succeeded. Native Bluetooth plugin compilation passed.
- The background SSH build failed signing. Reusing the previously demonstrated
  Mac Terminal `.command` execution method signed the same source successfully.
  No signing credentials, passwords or key permissions were changed.
- At the owner's renewed request, two dedicated test accounts were created through
  SP's normal signup API, with existing autoconfirm enabled. No confirmation emails
  were sent. Existing accounts/passwords were unchanged. Random test credentials
  remain in an ignored local private file, never in this document or source.
  Normal authenticated sessions were delivered through the SDK's existing auth
  callback handling; both real phone screens were observed at the campus map.
- Both devices correctly reported GPS outside the campus boundary. Their real
  off-campus positions were not published as map markers. Bluetooth discovery and
  lifecycle acceptance are still pending; installation/sign-in alone are not a pass.

These current iOS build observations supersede the earlier unavailable-Mac limit.
Detailed current device evidence is kept in ignored `output/nearby/`.

### Observed Bluetooth and lifecycle results

On the above physical builds, both foreground phones displayed **1 nearby / 0 on
map**. This occurred with actual GPS rejected outside campus, so no map position
was available to establish discovery. No synthetic encounter/receipt was inserted
for this phone test. Evidence: `android-ble-discovery-pass.png` and
`iphone-ble-discovery-pass.png` in the ignored evidence directory.

The owner then returned the iPhone to Home. Android changed to **Bluetooth on / no
players detected** (`android-after-iphone-background.png`). Reopening the iPhone
restored **1 nearby** on both phones (`android-after-iphone-resume.png`,
`iphone-after-resume.png`). Android was then sent to its actual launcher; the
resumed activity was verified as the Samsung launcher. The iPhone changed to
**Bluetooth on / no players detected** (`iphone-after-android-background.png`).
Returning Android to SP restored **1 nearby** on both phones again
(`android-final-resumed.png`, `iphone-final-resumed.png`). Both apps were left
foreground with discovery enabled. These observations establish cross-platform
foreground discovery, withdrawal on each platform's background transition, and
fresh rediscovery on each platform's resume for this device pair.

Still unverified physically: on-campus GPS marker placement/updates, range loss,
radio off, internet interruption, force quit, sign-out/account switching under
discovery, same-platform pairs and crowd capacity. Automated tests cover several
of these contracts but do not replace device observations. The owner also found
the green **Turn on** action easy to mistake for an enabled-state indicator; this
usability issue is recorded, and no UI revision was deployed during this test.

## Platform references

- [Plugin version and central/peripheral API matrix](https://pub.dev/packages/bluetooth_low_energy/versions/6.2.1)
- [Android Bluetooth permissions](https://developer.android.com/develop/connectivity/bluetooth/bt-permissions)
- [Apple Core Bluetooth programming guide](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/AboutCoreBluetooth/Introduction.html)

Android requests Nearby devices and retains location permission for older scan
rules/the existing map. No GPS read occurs in the Bluetooth radio. iOS declares
`NSBluetoothAlwaysUsageDescription` and relies on Core Bluetooth's system prompt.
