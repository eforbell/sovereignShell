# sovereignShell

A thin native iOS shell for a self-hosted household suite. The web apps stay the product; the native layer adds only what a browser can't do well.

The first app built on it is **Home Base**: a native launcher and onboarding screen for every household member, with administration served from the web.

- `Packages/SovereignShell`: the shared Swift package (web view host, Home Base client).
- `Apps/HomeBase`: the Home Base app target.
- `docs/plan.md`: what we're building, in what order, and why.

**Status:** planning and spikes. Nothing here is ready to install yet.

## Identity is configuration

Nothing that names a particular household or Apple team is committed. Your Apple Team ID and bundle ID go in `Config/Local.xcconfig`, which is gitignored. Household addresses are entered in the app at first launch, never compiled in.

## License

MIT
