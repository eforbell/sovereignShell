# sovereignShell

A thin native iOS shell for a self-hosted household suite. The web apps stay the product; the native layer adds only what a browser can't do well.

The first app built on it is **Home Base**: a native launcher and onboarding screen for every household member, with administration served from the web.

- `Packages/SovereignShell`: the shared Swift package (web view host, Home Base client).
- `Apps/HomeBase`: the Home Base app target.
- `docs/plan.md`: what we're building, in what order, and why.

**Status:** planning and spikes. Nothing here is ready to install yet.

## Identity is configuration

Nothing that names a particular household or Apple team is committed. Your Apple Team ID and bundle ID go in `Config/Local.xcconfig`, which is gitignored. Household addresses are entered in the app at first launch, never compiled in.

## Build Home Base

You need Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and a paid Apple Developer Program membership.

1. Register an App ID for Home Base at developer.apple.com (no extra capabilities yet).
2. Create its app record in App Store Connect, with that bundle ID.
3. Run `cp Config/Local.xcconfig.example Config/Local.xcconfig`, then fill in your Team ID and bundle ID.
4. Run `scripts/build-testflight.sh --no-upload` to check signing, then `scripts/build-testflight.sh` to upload.
5. Add the build to your internal testing group. TestFlight builds expire after 90 days.

For local work, `xcodegen generate` then open `SovereignShell.xcodeproj`. Package tests: `cd Packages/SovereignShell && swift test`.

## License

MIT
