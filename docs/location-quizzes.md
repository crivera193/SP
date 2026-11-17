# Location quizzes — November 17, 2026

Destination: `crivera193/SP`, based on main
`1640f576d3c52625905d658ae15f09410b5f20cf`.
Adapted reference: GOTest main `025d0255ec366a3f021a320f086f278eb619f416`.
GOTest's existing files and unfinished Bluetooth work were preserved.
The owner authorized committing and pushing this checked work to SP main using
crivera193 on November 17.

## Behavior

Locations open **A. True / B. False** quizzes. The current database-authored
placeholder is “Question:True or False”. Correct answers add one to that location's
team total; incorrect answers add nothing. Both owning and opposing teams may
play. Repeat play uses each location's editable cooldown, initially **600 seconds**
after an answer. Ties favor the team that reached that score first. Server locks,
canonical SP membership and idempotent receipts prevent duplicate awards.

`sp_quiz.locations` owns positions, animation types, art offsets, availability,
radii and cooldowns. Questions and immutable dealt answers remain private.
Team presentation comes from SP's existing catalog. The app refreshes locations
on entry, foreground return, quiz return and every five foreground seconds;
backend failure shows an explicit notice rather than invented gameplay data.

The existing raw foreground GPS stream independently switches each location
between a diamond and its horse/plant/cats. Initial settings retain **25 m entry /
40 m exit**, three seconds of distinct provider evidence, at most 15 m reported
uncertainty and at most 10 seconds of fix age. Tapping opens the quiz only after
confirmed proximity entry with a fresh eligible fix, rechecked at tap time.
Outside diamonds cannot open it. Taps do not control revelation.
Departure or unavailable GPS restores diamonds. The owner's
team hue applies to both forms, retaining Lottie shading and dark details.

SP's encrypted offline friend protocol is reused. Only an accepted friend with
a proved, open Bluetooth session may supply a map position. Close or local
removal withdraws it immediately. The legacy online endpoint now checks accepted
friendship too. Offline remote-removal limits remain as documented in
[nearby-players.md](nearby-players.md).

## Applied backend

The owner authorized deployment on November 17. Applied once, through the
authenticated **crivera193** dashboard, to **bsvcnndqvjizxgnxhxkd / SProject_2.0**:

- `20261117010000_sp_location_quizzes.sql`
- `20261117011000_sp_friend_only_positions.sql`

**Do not replay them or previously applied team/friend migrations.** Migration
files retain the originally reviewed text; this record supersedes their initial
pending-status comments. No other backend or signup policy was changed.

Readback found three locations, one placeholder, private question schema and RLS,
authenticated-only quiz RPCs, and the accepted-friend predicate in the legacy GPS
query. The original **13 accounts / 6 memberships** and team-function hash were
unchanged. Actual signed-in REST calls from both existing QA accounts read the
same live scores; anonymous catalog access returned HTTP 401.

## Verification and devices

Flutter 3.47.7: analysis clean; **95 Flutter tests passed**. The local PostgreSQL
checks also passed (`node tool/check_quizzes_sql.mjs` and
`node tool/check_friends_sql.mjs`). A duplicated GPS notice discovered on the
phone was removed and covered by an additional widget test.

Both devices were updated in place to **12063**, with matching signing identity,
retained first-install identity and pulled installed APK bytes matching the fresh
builds. Native package/version/signature overrides reuse the established SP test
build scripts. No source package configuration was left modified.

- Samsung SM-S948U1: release `com.example.campus_app.spverify`, SP Bluetooth Test.
  APK SHA-256: `67d415c9b7b02d8cce29990c07563ff05e5a2dc132e104ded39f55568c87ca4b`.
  The original `com.example.campus_app` remains version 12049. The saved Art and
  Stuff membership and existing friend code were observed after the in-place
  12062 update; final 12063 changes only suppress the duplicate notice. The phone
  locked before final screen readback; no lock/security bypass was attempted.
- SP_Walking_Crash_API36_1: x86_64 debug 12063, 1080×2400.
  APK SHA-256: `46a7c7217f94ca8a8cfbbaa2111d0ccda709cc91198b9889592a618648fc46ce`.
  Fresh **simulated emulator GPS**, never phone GPS, exercised automatic horse
  entry and diamond exit, plant entry, and all three cat instances. Actual native
  views were inspected. At the exact anchor the existing avatar overlaps artwork;
  this pass preserved that existing layering. A later off-anchor inspection could
  not be completed because Android UI inspection intermittently returned an empty
  hierarchy while the emulator was idle. Those attempts are not counted as passes.

The existing QA account loaded the actual live question. One correct Bronco
answer on 12062 saved **one Art and Stuff point**, showed the ten-minute cooldown,
and updated the other client's owner/color. This history was retained. Final
12063 loaded the Kitty Island quiz; False was rejected, awarded zero, and showed
its cooldown. Other locations retain zero scores. Phone GPS was untouched.

Evidence and sanitized readbacks are under ignored `output/quizzes/`:
`backend-live-20261117.json`, `final-device-install.json`, native captures and
`deployment-verification-20261117.json`. The existing Mapbox/Bluetooth Kotlin
Gradle future-compatibility warning remains.

These initial checks used emulator GPS. Physical BLE interoperability and iOS
compilation were subsequently checked below. Outdoor GPS and normal-speed
animation acceptance remain outside the observed coverage.

## Physical-phone follow-up — November 17

The owner unlocked the Android phone, made the iPhone available, and explicitly
authorized temporary simulated campus GPS. Both physical phones used synthetic
public campus coordinates; real location histories were not recorded.

Final builds are Android release **12064** (`com.example.campus_app.spverify`) and
iPhone Xcode Release **11** (`com.example.campusApp`). Both contain native source
fingerprint `883faa62d52118719d939588875b8084d420e2f855648ff6e19569cc0707c950`.
Android APK SHA-256 is
`4f70acbe841473d5c029bff6cda9475cfb2e265e312328e4b25abfca15dc8af3`.
Installed Android bytes match. Existing signatures, installation identity, SP
accounts and data were preserved; the original Android testing app remains 12049.
The iOS team/profile were retained, with profile expiry November 24. Source
Android package files were restored after the existing test-build overrides.

Observed checks:

- Android loaded the live placeholder. True added one point; reopening retained
  the cooldown and saved result. Bronco now has **two Art and Stuff points**.
  False at Monstera awarded zero. On final 12064, playing Monstera again after the
  earlier cooldown expired worked, again awarded zero for False, and started a
  new ten-minute cooldown. Its score remains zero/unclaimed.
- Before opening a verified Bluetooth session, both phones discovered the other
  with zero map positions. After mutual proof, both reported one map position.
  Actual full-map screenshots on final builds show each other's marker. Changing
  the iPhone's synthetic fix moved its Android marker.
- Closing the session on final 12064 withdrew its marker immediately; iPhone 11
  subsequently reported zero map positions. Removing the dedicated test friend
  through normal Friends UI left it detectable but communication locked, with
  zero map positions and no opening control on Android.
- Automatic proximity entry was observed on the physical phone. Removing the
  GPS override restored outside-proximity diamonds without a marker tap.

The first physical run exposed GPS stalls: an outstanding packet ACK blocked
newer position data, and the original six-second GPS lifetime was tight for a
four-second Bluetooth refresh plus transfer/retry. The GPS queue now supersedes
its older pending position with the latest fix or GPS-loss update. The encrypted
proof, packet format, replay checks and reliable close/hello behavior remain.
A regression test failed before the fix and passed after it, including GPS loss
while ACKs are withheld. Analysis is clean and **96 Flutter tests passed**.

SP's existing live `fix_s` setting was tuned to **12 seconds**; heartbeat remains
four seconds and accuracy remains 40 m. Only that settings row changed. Existing
prepared clients load it through normal Friends refresh or account bootstrap.
The setting change alone did not eliminate the stall; the final builds include
the queue correction too. No schema migrations were replayed.

Final map readbacks and screenshots showed sharing in both directions. Screen
inspection intermittently failed on both platforms; these samples are recorded
as unavailable, not passes. This is a focused two-phone check, not uninterrupted
long-duration/range or crowd validation. Wi-Fi/cellular stayed in their existing
states for this pass; the earlier physical offline checks and current no-network
protocol tests are separate evidence. Outdoor walking GPS, same-platform pairs
and fresh physical airplane-mode testing remain unverified.

Cleanup removed both GPS overrides, restored Android's shell mock-location mode
to default, stopped test discovery, and returned the dedicated QA friendship to
its initial removed state. iPhone's normal account bootstrap synchronized that
removal. No accounts, memberships, scores or saves were reset. These checks
completed before the owner authorized Git publication to SP main.

Current evidence is in ignored `output/quizzes/physical-testing-20261117.json`,
`physical-gps-build-install.json`, `physical-gps-steady-12064.json`,
`phone-12064-verified-map.png`, `iphone-11-verified-map.png`,
`phone-12064-quiz-repeat.png`, `phone-12064-nonfriend-blocked.png` and
`gps-freshness-12s.jpg`. Earlier 12063/10 readbacks are retained as historical
evidence, including the failed timing-only attempt.

## Subsequent UI revision

The question and True/False answers now precede a horizontal team-color bar chart.
Bars scale to the highest score; zero scores retain empty colored tracks. The
map GPS status banner and automatic
arrival card are removed; point taps and location eligibility checks remain.
The Bluetooth introductory blurb and the Friends paragraph above the friend code
are removed, as clarified by the owner. The Friends display/copy widget check passed.

Analysis and all 96 Flutter tests passed for publication. Android emulator
build 12065 was installed in place and inspected at 1080×2400 with live SP quiz
data: question first, all three team bars and no arrival popup. The later Bluetooth
wording correction passed the panel's enable/disable widget check. No answers
were submitted during this UI preview. Native
captures are `output/quizzes/quiz-layout-native-12065.png`,
`map-no-gps-popups-12065.png`. The older `bluetooth-wording-12065.png` capture
predates removal of the blurb.
The physical phone apps were not updated in this pass. The owner authorized
committing and pushing all remaining updates to SP main on November 17.

The owner subsequently requested the placeholder text replacement above. It was
applied live to `sp_quiz.questions` on November 17 (question version 2). Unanswered
attempts containing the previous wording were retired so reopening loads the new
text; answered history, cooldowns, scores and ownership were preserved. The quiz
display widget check passed with the updated prompt.

The subsequent proximity-only opening change passed analysis and all seven
location quiz tests, including outside, nearby, lost eligibility and exit taps.
Android emulator build 12066 (1080×2400, synthetic campus GPS) was installed in
place: tapping Kitty Island's outside diamond kept the map open; entering its
proximity and tapping its cat opened the quiz. No answers were submitted.
Captures are `output/quizzes/proximity-outside-12066.png` and
`proximity-inside-quiz-12066.png`; artifact identity and signing checks are in
`output/quizzes/proximity-open-install.json`. Physical phones were not updated.

The owner's subsequent highlighted-text correction removes the tie explanation
and location description from the quiz display. Analysis and all seven quiz
tests passed. Emulator build 12067 was inspected at 1080×2400; screenshots are
`output/quizzes/quiz-cleaned-12067.png` and `bluetooth-modal-12067.png`.
