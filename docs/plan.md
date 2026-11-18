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
- **Admin opens in a Safari view for now.** The app's web view can't use passkeys scoped to the tailnet domain (see above), and Safari can. Phase 3 may change this.

### 3. Step-up passkeys

- The handoff chosen by spikes b–d.
- If it's a ticket exchange: a Home Base (and possibly sovereignAuth) endpoint that issues and redeems a one-time ticket, plus the app side.

### 4. Enrollment without passing codes

- The administrator issues a passkey grant on the Members card, as today.
- The member's app picks it up over the tailnet, for its own member only, so no code is passed by hand.
- The grant is still consumed when the registration verifies, never when the app fetches it.

### Later

- The phone as an approval key: the App Attest–backed "attested device" from the iPhone hardware-key research.
- Push for approval prompts, using the Home Base app's own topic on the household's push gateway.
- Widgets.
- Per-app targets for other suite apps.
- The `window.sovereign` bridge, when a web app first needs it.

## What stays manual

- **Joining the tailnet.** It's operator-assisted and kept out of the app on purpose.
- **Admission and app grants.** These remain the administrator's decisions on the Members card.
- **The Apple side:** the developer program, App IDs, the App Store Connect record, TestFlight testers, and a new build every 90 days.
