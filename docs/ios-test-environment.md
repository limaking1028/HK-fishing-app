# iOS test environment

Based on `codex/push-1-ios` / PR #74, commit `81eef7f`. Merge #74 first.
Only iOS build tooling/output changes; root web app, Android and root libraries remain unchanged.
The historical isolation diff is a behavior reference, not an applied patch.

## Build

Explicitly select `APP_ENV=prod npm run ios:web` or
`APP_ENV=test HKF_TEST_SUPABASE_ANON_KEY=<public anon key> npm run ios:web`.
Use the same environment when running `npm run ios:sync`. Generated `www/` is ignored.
The build deletes stale output before validating configuration. Test key must be an anon JWT
for `qyijyrcbzalvqiautvjf`, or a Supabase publishable key. Service role JWTs are rejected.
For opaque publishable keys, project association must be confirmed in the Supabase dashboard;
it cannot be inferred from the key. Never use a secret key.

Both bundles contain `hkf-env.js`/`hkf-env.json` with env, ref, URL and public anon key.
An independent env/ref seal in index is checked synchronously before app scripts.
Missing/invalid manifests stop boot, with a visible error, without a database fallback.
All Supabase creation paths use the same checked manifest and explicit session storageKey.
The build scans **every file** in both outputs for the other environment’s ref and refuses contamination.

Test: fixed yellow 測試環境 banner, test database, password login only, disabled
Apple/Google/register/OTP/reset controls and API methods, exact
`app.hkfishing.ios://auth-test-callback` PKCE callback (implicit tokens rejected).
Prod: current production database, mail/OAuth/password behavior and production callback preserved.
No generated app script uses raw local/session storage; iOS output routes through the adapter.
Push uses the same environment client; its prompt flag is namespaced, and APNs token/prefs
remain in memory, registering only with that client's database. No startup permission prompt.
SW fetch still only intercepts same-origin fish photos. Cache lookups and activation cleanup
are limited to the current environment/ref prefix; old and other environment caches survive.

## Legacy migration policy

The brief's blanket “count only” and prod compatibility requirements conflict. This implementation
uses count-only access in **test**, and controlled read/copy without deletion in **prod**.
New keys: `hkf:v2:<env>:<ref>:<owner>:<kind>` (parts percent-encoded).
User data follows the authenticated owner; shared device preferences use owner `device`;
auth uses owner `auth`. Session storage is independently namespaced too.

Test never reads values, copies, uploads or deletes legacy keys, including old sessions,
unsynced catches, tallies and active-trip markers. `HKF.legacyCount()` only enumerates names.
Prod copies allowlisted legacy preferences on first read. User data requires the old
`hk_fishing_user_id` (or preserved legacy auth session owner) to match the authenticated user. Unsynced catches are additionally
filtered by their explicit `userId`. Tallies reload after setting the authenticated owner;
trip recovery continues to validate against cloud trips. Unknown-owner data stays untouched.
The legacy production Supabase session may be copied to the new explicit session slot.

Writes always use new keys. Deletion writes an empty tombstone to the new key so a preserved
legacy queue/session cannot be resurrected on the next startup. Account deletion clears only
the current owner and this environment's auth slot. In prod, account deletion also filters
legacy catch/unsynced/imported arrays by explicit `userId`/`user_id`, removes explicitly owned
legacy objects, removes a legacy auth session only if `session.user.id` matches, and removes
that user's exact legacy push prompt flag/ID marker. Conflicting, missing or malformed ownership
is preserved; in particular ownerless trip/tally/preferences cannot safely be attributed from
one last-user marker. Other users' unsynced records are never removed. No regex deletion.
Outside explicit account deletion, original legacy values remain for rollback to an old App Store binary. No legacy data is
silently claimed by a different user. Existing cloud behavior for older catch caches is retained
(the current source's `migrateLocalCatches()` is intentionally a no-op).

## Manual Codemagic workflows

No workflow has a `triggering` block. Existing simulator/release workflows explicitly use prod.
New `ios-testflight-test` uses test and the same `app.hkfishing.ios` bundle identifier.
Configure environment group `hkf_test_environment` with `HKF_TEST_SUPABASE_ANON_KEY` in
Codemagic UI. Do not commit the key. Release signing/publishing steps are unchanged.
Both workflows use the identical integer `latest TestFlight build number + 1` calculation;
a test upload advances the same App Store Connect sequence and the next prod build can increment
it normally. The workflows/banner identify the environment, not a separate number format.
A local fake-CLI regression executes the actual YAML shell snippets for test then prod and
verifies consecutive integer values. As with the existing workflow, run submissions serially
to avoid two simultaneous builds selecting the same latest number. Same bundle ID means installing test replaces prod on the device;
namespace isolation protects local data, but OS notification permission is shared by that ID.

Validation is local/offline: Node VM tests, both generated bundles, auth/SW/push mocks and browser
regressions. No remote SQL, merge, deployment, Codemagic invocation, signing or TestFlight upload.
Real iPhone, APNs delivery, dashboard key configuration, Xcode signing and Codemagic remain
manual validation items. No passwords, service-role keys or signing material are used.

## Acceptance regression checks

`npm ci` installs the Supabase JS SDK as a dev/test dependency only (not copied into www).
The session upgrade test uses the real SDK default storageKey and `getSession()`, an unexpired
synthetic session, and a fetch stub that rejects all network calls. It verifies the old session
is still authenticated after migration, the old key remains byte-for-byte, and an existing new
slot or logout tombstone is never overwritten. No real tokens or accounts are used.

The generated-browser smoke checks 0px and simulated 59px safe areas at 390×844. Banner height,
body inset, sticky header, login screen and tutorial bar share one CSS height; the header does
not duplicate safe-area padding. Screenshots are local mock/tutorial previews, not real-device
validation. `HKF_SCREENSHOT_DIR` selects where to save the page-top and tutorial images.

Committed review screenshots (390×844 viewport, 2× scale, simulated 59px top safe area,
local fixture user only):

- [Test page top](screenshots/test-env-top-safe59.png)
- [Test tutorial bar](screenshots/test-env-tutorial-safe59.png)
