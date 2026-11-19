# Plan: the Home Base app on SovereignShell

Started 2026-11-18. This is the working agreement for the first native app. It replaces the "native shell" section of the earlier push research. Where the two disagree, this document wins.

## Decisions

1. **The first native app is Home Base.** Home Base's `/` route is already a launcher for every household member, not only the administrator. It's also where a new household onboards its members, so it's the app people will open first.
2. **The push app stays separate.** It carries notifications as the household's alternative to a hosted push service, and Home Base doesn't manage it. It doesn't use this package for now. Two TestFlight apps are fine.
3. **Native where it pays, web everywhere else.**
   - **Native:** the launcher and onboarding.
   - **Web view:** administration. Some admin screens are busy and will probably need UI work for a phone, but they should work as they are.
4. **Kids are in scope from the first build.** They're already TestFlight users.
5. **Identity is configuration.**
   - The team ID and bundle ID live in a gitignored `Config/Local.xcconfig`. The display name is "Home Base".
   - Household addresses are entered at first launch and never compiled in.
6. **This repo is public.** Nothing that names a household, host or Apple team gets committed.

## What Home Base already provides

`GET /api/home` returns everything the native launcher needs, already filtered on the server for the caller:

```json
{ "state": "member", "caller": { "name": "…", "login": "…" }, "canUnlockAdmin": false,
  "apps": [{ "id": "family-dinner", "name": "Dinner", "icon": "🍽", "url": "https://…" }] }
```

| `state` | What the app shows |
|---|---|
| `member` | The launcher: the apps this member may open. An empty list says to ask the administrator. |
| `waiting` | "Your administrator needs to add you." Re-checks every 10 seconds while visible. `candidateObserved` says whether the visit was recorded. |
| `unidentified` | Home Base can't see a tailnet identity: "Connect to your household's tailnet, then try again." |
| `disabled` | Access unavailable. |
| `unavailable` | Home Base can't check membership right now; retry. |
| `setup`, `recovery` | The household isn't ready yet. Administrators get a link to Admin. |
| `administrator` | An unlocked admin session: offer Admin (web). |
| `legacy` | The directory is off: open Home Base's web dashboard. |

Identity comes from the tailnet. A request from the app goes through the phone's tailnet connection, the same as Safari, so Home Base sees the same member. Opening Home Base or any app needs no sign-in. Passkeys only matter for step-up actions: unlocking administration, and the few app screens that ask for one.

## Layers

| Layer | What it holds |
|---|---|
| `SovereignShell` package | Home Base client (`/api/home`), the web view host and its link rules, and later the `window.sovereign` bridge, the passkey handoff, and shared identity and keys |
| `Apps/HomeBase` | The app target: icon, name, the native launcher and onboarding, settings |
| Home Base (web, separate repo) | Unchanged at first. Later: a passkey handoff endpoint and identity-bound enrollment pickup |

New native apps can join later as more targets on the same package. Nothing locks the suite into one app.

## The open risk: passkeys inside an app's web view

Home-screen web apps run in Safari, which may use passkeys for any site, from any provider such as 1Password. A `WKWebView` inside a third-party app is different. Apple's passkey documentation says such a web view can use passkeys only for domains in the app's associated domains.

That's out of reach for us:
- Home Base registers passkeys for the **tailnet domain** (`rpID` is the ingress domain, such as `example.ts.net`), not for its own hostname.
- An app can claim a domain only if that domain serves Apple's association file. Normally Apple's CDN fetches it, and its development and managed-device modes only change how it's fetched.
- Nothing serves the bare tailnet domain, so no build or distribution mode makes the claim valid.

So unlocking administration inside the app's web view is expected to fail. The likely way through is to run the ceremony where Safari's rules apply:
1. `ASWebAuthenticationSession` opens the passkey step.
2. Home Base returns a one-time ticket to the app through a callback.
3. The app's web view exchanges the ticket for its session.

`SFSafariViewController` is a simpler fallback, at the cost of Safari's toolbar. The spikes below settle which one we use.

## Phases

Each phase lands as small PRs touching few files.

### 0. Spikes (throwaway screen in the first TestFlight build)

| | Question | Expected | How |
|---|---|---|---|
| a | Does a native request and a web view on the tailnet hostname get the caller's identity from `/api/home`? | Yes | Fetch natively and load `/` in a web view; compare the `state` and caller |
| b | Can the in-app web view use a passkey (1Password or iCloud Keychain) on Home Base? | No, but confirm | Unlock administration in the web view; also a direct `navigator.credentials.get` probe, scoped to the tailnet domain, showing the exact error |
| c | Does `ASWebAuthenticationSession` run Home Base's passkey unlock, YubiKey included? | Yes | Open Admin in a session and unlock |
| d | Does `SFSafariViewController` run it? | Yes | Same, in a Safari view |

Run them from a TestFlight build on a real phone. Write the results into this document before phase 3.

**Results (2026-11-18, iOS 26.7, TestFlight):**

| | Result |
|---|---|
| a | The web view identified the member over the tailnet. The native request got `403 fetch_metadata_missing`, which is fixed by sending first-party fetch metadata (see phase 2 findings). |
| b | **Fails**, as expected: the app's web view can't use passkeys scoped to the tailnet domain. |
| c | **Unlock works**, with passkeys and hardware keys. The session can't return to the app yet, because Home Base has no return link: it ended only when cancelled (`WebAuthenticationSession` error 1). That return link is exactly what phase 3's handoff adds. |
| d | **Works**, with passkeys and hardware keys. |

Phase 3 chooses between:
- **c plus a handoff:** the session ends on a one-time ticket, and the app's web view redeems it for a session. This needs a Home Base change, and admin stays in the app's web view.
- **d alone:** administration and other step-up pages live in a Safari view, with no Home Base change. The Safari view has its own cookies, which persist across launches.

### 1. Scaffold

- The package and the app target (XcodeGen).
- Operator config.
- `scripts/build-testflight.sh`.
- The App Store Connect record for Home Base (a manual step for the operator).

### 2. Native launcher and onboarding

- First launch asks for Home Base's address: typed, or by scanning a join code that carries only the address and grants nothing.
- The app renders every `/api/home` state natively.
- If the address can't be reached at all, the app says the phone may be off the tailnet.
- Apps open in an in-app web view. Links to other sites open in Safari.
- An administrator gets "Open Admin" in a web view.
- No changes to Home Base.

**Found while building it (2026-11-18):**
- **Fetch metadata.** Home Base's hostname is strict (sovereignAuth wire contract §4.1), so it refuses any request without fetch metadata. A plain native request got `403 fetch_metadata_missing` from a real install.
  - The client now sends what Home Base's own pages send for an API call: `Sec-Fetch-Site: same-origin`, `Sec-Fetch-Mode: cors`, `Sec-Fetch-Dest: empty`.
  - That guard keeps browser sites apart. It isn't authentication, and no web page can drive the app's native requests.
  - The web view's own page loads are ordinary navigations and pass unchanged.
  - Tested against a real install: `/api/home` answered 200, and the response decoded.
- **Admin opens in a Safari view for now.** The app's web view can't use passkeys scoped to the tailnet domain (see above), and Safari can. Phase 3 brings it back into the app.

### 3. Step-up passkeys

The handoff: the web view asks the app to run a passkey ceremony in an ephemeral sign-in sheet, and the app proves it's the household's genuine app with App Attest. The design is sovereignAuth's `docs/native-handoff.md`, built in six slices; this repo's part is the last.

**Spike results (2026-11-18, iOS 26.7, TestFlight):**

| | Result |
|---|---|
| 1 · App Attest | **Works in production.** A Node prototype of the server checks passed all 22 (Apple chain, nonce, key ID, App ID hash, production environment, receipt, three assertions with rising counters), and the controls failed as they should. |
| 2 · Ephemeral sheet | **Works** with 1Password and a YubiKey over USB-C. Not tested: iCloud Keychain (used before in the same kind of sheet), YubiKey over NFC (none available), and whether the sign-in alert is skipped. |
| 3 · Sheet identity | **Same member** in the sheet as in a native request. |
| 4 · Sheet closing | Folded into Home Base slice 4: the sheet page navigates to the callback and always shows a return button too. |
| 5 · Pinning | **Holds.** Refusing every anchor blocked both the native request and the web view's load. The ISRG anchors passed on *leaf ← YE2 ← Root YE ← ISRG Root X2*. With them, the web view loaded Home Base on one passed challenge (all 12 resources shared the connection), and the page's `fetch` of `/api/home` returned 200. |

The pin set needs Root YE and Root YR once Apple trusts them, before Let's Encrypt drops the X2 cross-sign.

**Built (2026-11-19):** sovereignAuth #12 and #13, Home Base #66–#70, and this repo's slice 6:
- **6a, household trust:** household hosts load only over the pinned authorities, for the app's own requests and in the web view. The phase 3 spike screen is gone.
- **6b, the handoff:** on first use the app registers this installation with an App Attest key. Household pages get `window.sovereign` (version 1) in their main frame. `handoff(id)` attests the id to the page's own host, opens the ephemeral sheet, and resolves when it returns to the app's callback scheme (its bundle ID), or rejects with `cancelled`, `unavailable` or why. Admin opens in the app, and unlocking it goes through the sheet. Registering a passkey stays in Safari, from the menu.

**Verified on a phone (2026-11-19, TestFlight):** unlocking Home Base's Admin and a sensitive app's passkey check both ran through the handoff inside the app: registration on first use, App Attest, the sheet, and the result back in the web view. In homeSource, a check with a YubiKey over USB-C in the sheet worked too. An every-time action (restarting an app from Admin, with the hardware key) went through the sheet and ran the job. After changing household to a second Home Base, the app registered there on its own; a step-up in that household's Bitcoin Accounting, Admin unlock and an app backup all worked.

Not yet tried on the phone: iCloud Keychain and YubiKey over NFC in the sheet.

Found on the phone, fixed in Home Base: the sheet showed an every-time action's raw target instead of what it does (Home Base #71), and Admin took 6–10 seconds to paint in the app's web view because Home Base read its state before serving each static file.

Still to do:
- Add Root YE and Root YR to the pinned set once Apple trusts them.
- Enroll passkeys from the app (phase 4); until then, registering one stays in Safari.

### 4. Enrollment without passing codes

- The administrator issues a passkey grant on the Members card, as today.
- The member's app picks it up over the tailnet, for its own member only, so no code is passed by hand.
- The grant is still consumed when the registration verifies, never when the app fetches it.

### Later

- The phone as an approval key: the App Attest–backed "attested device" from the iPhone hardware-key research.
- Push for approval prompts, using the Home Base app's own topic on the household's push gateway.
- Widgets.
- Per-app targets for other suite apps.
- A switcher of recently used households, for operators who run more than one Home Base. Today "Change household" forgets the address, and switching back means typing it again.

## What stays manual

- **Joining the tailnet.** It's operator-assisted and kept out of the app on purpose.
- **Admission and app grants.** These remain the administrator's decisions on the Members card.
- **The Apple side:** the developer program, App IDs, the App Store Connect record, TestFlight testers, and a new build every 90 days.
