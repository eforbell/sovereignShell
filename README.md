# sovereignShell

A thin native iOS shell for a self-hosted household suite. The web apps stay the product; the native layer adds only what a browser can't do well.

The first app built on it is **Home Base**: a native launcher and onboarding screen for every household member, with administration served from the web.

- `Packages/SovereignShell`: the shared Swift package (web view host, Home Base client).
- `Apps/HomeBase`: the Home Base app target.
- `docs/plan.md`: what we're building, in what order, and why.

**Status:** in use through TestFlight. Home Base's launcher works, and so do passkey checks inside the app, through the native handoff. A member's first passkey can be added in the app by scanning the administrator's code (checked with iCloud Keychain). Setup and recovery happen in Safari. See `docs/plan.md` for what's next.

## Identity is configuration

Nothing that names a particular household or Apple team is committed. Your Apple Team ID and bundle ID go in `Config/Local.xcconfig`, which is gitignored. Household addresses are entered in the app at first launch, never compiled in.

## Build Home Base

You need Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and a paid Apple Developer Program membership.

1. Register an App ID for Home Base at developer.apple.com, with the **App Attest** capability.
2. Create its app record in App Store Connect, with that bundle ID.
3. Run `cp Config/Local.xcconfig.example Config/Local.xcconfig`, then fill in your Team ID and bundle ID.
4. Run `scripts/build-testflight.sh --no-upload` to check signing, then `scripts/build-testflight.sh` to upload.
5. Add the build to your internal testing group. TestFlight builds expire after 90 days.

For passkey checks inside the app (the native handoff), Home Base needs to know the app. Set these in its env file and restart it:

```
HOME_BASE_NATIVE_APP_ID=<TEAMID>.<bundle id>
HOME_BASE_NATIVE_APP_SCHEME=<bundle id, in lower case>
```

The app's sign-in sheet returns to its own bundle ID, so the scheme is the bundle ID in lower case.

The app trusts household hosts only through the certificate authorities in `Apps/HomeBase/TrustAnchors/`: Let's Encrypt's ISRG Root X1 and X2 by default, which Tailscale's certificates use. If your household's certificate authority differs, replace those files and ship a build.

For local work, `xcodegen generate` then open `SovereignShell.xcodeproj`. Package tests: `cd Packages/SovereignShell && swift test`.

## License

MIT
