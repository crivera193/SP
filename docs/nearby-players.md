# Nearby players and friend sessions in SP

SP is `crivera193/SP`. Supabase: **bsvcnndqvjizxgnxhxkd**, **SProject_2.0**.
UTRGV-GOTest is outside scope. These Bluetooth changes are based on main
`a8ea6e9252395244cede19626e7edafe5204a129`. On November 16, the owner authorized
committing and pushing this checked work to SP main using crivera193.

## Current behavior — November 16, 2026

Nearby discovery and opening/maintaining a verified friend's Bluetooth session
work without internet. Other app features retain their normal internet behavior.
**Chat is outside scope.** The final source has no chat box, Send button, text
message handler, text send API or displayed history. The owner corrected an
unrequested chat addition; manual text testing stopped and that feature was removed.

Public friend codes are now eight hexadecimal characters grouped `ABCD-1234`.
Display/copy and online lookup use this alias; full UUIDs and Bluetooth keys remain
unchanged. A unique database index prevents ambiguous codes.

The separate online **Friends** screen handles friend-code request, explicit
recipient acceptance, refresh and removal. Crossing requests do not implicitly
accept. Only accepted parties receive the private pair credential; pending users
and outsiders receive no key. Readding a removed relationship rotates its key.
The account/project-scoped verified book persists in the private app sandbox,
independently of login-token expiry. Local removal is persisted immediately;
an offline phone learns a remote removal on its next normal online friend sync.
Instant remote revocation while disconnected is impossible. The backend knows pair
keys; this is not secrecy from the backend.

Production MapScreen gives Bluetooth only VerifiedFriendBook data and offline
repositories, with no Supabase client or online callback. Ordinary account
bootstrap/Friends owns online sync. Missing cached identity/config shows an explicit
preparation notice. Existing login/team/map gates retain normal online behavior.
If the online team/session check fails, a separate **Nearby players** entry can
load the current account's saved Bluetooth book without opening team/game routes
or running friend sync. `OfflineNearbyEntry` owns and disposes its local radio and
controller; it receives no online client. An account without prepared credentials
gets an explicit setup notice. Sign-out/account changes dispose the entry.
Legacy online nearby/friend adapters remain unused by production Bluetooth.

BLE v2 service `...7101` separates the new protocol from v1 `...7001`; old builds
must update. GATT exchanges fresh 16-byte session IDs/public friend codes.
Nonfriends remain detectable and locked. A known label is an identity hint until
mutual encrypted key proof succeeds. Only then is **Verified Bluetooth session**
shown. These are application sessions over short BLE GATT exchanges, not RFCOMM
or an OS socket allowlist. Restricted discovery connections may occur with
nonfriends without granting protected application data.

Each open derives a fresh HMAC-SHA256 key from the verified pair credential,
relationship, both fresh discovery IDs and a random offer ID. AES-256-GCM binds
channel/version/direction/sequence; bounded baseline-ATT fragments, replay checks
and authenticated ACKs support retries without duplicate delivery. Only a proved
session may share existing GPS position data, with freshness/bounds checks. GPS
never establishes encounters. Close uses encrypted protocol close/ACK. Background,
radio failure/off, account exit and disposal withdraw sessions. No Bluetooth
background service/mode was added. Old text packets are ignored.

## Backend and current artifacts

Verified dashboard account **crivera193** and exact SP destination before applying:

- `20261115010000_sp_friend_communication.sql`: private RLS friend tables and
  legacy online session grants.
- `20261116010000_sp_offline_friend_directory.sql`: private pair credentials and
  three authenticated-only online directory RPCs.
- `20261116020000_sp_durable_offline_friends.sql`: durable offline trust independent
  of JWT expiry; online setup still checks valid authentication.

- `20261116030000_sp_short_friend_codes.sql`: unique eight-character lookup aliases
  and an authenticated-only wrapper preserving explicit recipient acceptance.

All four were applied once November 16. Do not replay. Live readback verified
private table denial, authenticated-only RPCs, durable trust, unchanged signup/team
function hashes and unchanged account count (13). Evidence is in ignored
`output/friends/backend-live-20261116.json` and `backend-offline-live-20261116.json`.

Final native-source fingerprint:
`8f61e2763d2c0679455bab1baceee78c46fd5a6060ec07e017eb7d14d20fe3d0`.

- Android SM-S948U1: release **12060**, existing separate package
  `com.example.campus_app.spverify` (SP Bluetooth Test), APK SHA-256
  `929c954a21283aa68e967c31e0c09fba51f0d694f1bea82b486c8e42ed71e922`.
  In-place install, installed bytes match, signing and November 6 first-install
  time retained. Original `com.example.campus_app` remains 12049.
- iPhone 13 Pro Max: Xcode Release **8**, `com.example.campusApp`, team
  `6QF59C684U`, original signature/device profile verified (expires November 24).
  Mac/Windows native-source fingerprints match. In-place install succeeded.
  It subsequently launched successfully after normal iOS developer verification.
  No security settings were bypassed.

## Current verification

The owner limited final physical acceptance to two checks. Both passed on the
above Android **12060** / iPhone **8**, whose native-source fingerprints matched:

1. With the iPhone's Wi-Fi and cellular data off and Bluetooth on, both foreground
   phones detected **1 nearby / 0 on map**. Real GPS outside campus did not create
   the encounter. After normal online friend setup, opening a session showed
   **Verified Bluetooth session** on both phones while the iPhone stayed offline.
   Captures: `output/friends/final-friend-offline-android.png` and
   `final-friend-offline-iphone.png`.
2. Android closed the session and removed the dedicated test friendship through
   normal Friends UI. It still detected the iPhone but showed **Detected ·
   communication locked**, with no opening control. The offline iPhone retained
   its old friend hint and attempted an open when the owner tapped it. It stayed
   **Waiting for your friend's verified Bluetooth reply…**; Android stayed locked.
   No verified session was granted. Captures: `final-nonfriend-denied-android.png`
   and `final-nonfriend-denied-iphone.png`. The test friendship remains removed.

No chat controls or manual chat payloads were used for these final checks. Prior
chat experiments are superseded and outside the accepted feature. The iPhone
XCTest helper never completed its OS automation authorization; these are observed
phone results with owner taps, Android ADB input and screen readback.

For the subsequent short-code change, Dart analysis is clean and **86 Flutter
tests passed**, including actual Friends display/copy and preservation of the full
Bluetooth identity. All three SQL harnesses passed before the alias change; the
updated offline-friends PGlite harness passed with formatted/case-insensitive
lookup, collision rejection, consent, key isolation and permission checks. Live SP
readback confirmed unique aliases, security-definer lookup, authenticated execute,
anonymous denial and unchanged account count (13). Evidence:
`output/friends/short-code-backend-verified.jpg`.

Short-code native source fingerprint:
`02120722cbaf831ddcb34661e7f6578b3dfaa23d5e5793a05c8d87bb4ea82da5`.
Android **12061** / iPhone **9** are built, signed, installed in place and launched.
Installed Android APK bytes match SHA-256
`70aa87cf5e7db825ccb8f82e7838a59e942ab9711e2fa5da7f8ad041419b1f30`; original signing,
first-install identity and original app12049 are preserved. Android Friends visibly
shows `AA50-621E` with readable controls and no overflow. iPhone bundle/version9
was read back and its normal map/current account observed after the owner restored
Wi-Fi for normal developer verification. Its short-code panel was not separately
opened; the shared widget passed display/copy tests. Bluetooth transport and friend
authentication are unchanged; the two physical results above apply to the protocol
they exercised. Evidence is in `output/friends/short-code-build-evidence.json`.
No additional lifecycle, same-platform, crowd or on-campus position tests were
added to the owner's two-check acceptance scope. Git publication is separately
authorized by the owner; backend migrations were already applied and must not replay.

## Historical v1 discovery implementation

The retained documentation below describes the earlier server-assisted discovery
implementation and November 6 phone observations. Current behavior is defined above.

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
