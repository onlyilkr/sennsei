# Releasing

One-time setup (repository settings):

1. Enable private vulnerability reporting (Security > Advisories).
2. Create two environments, both restricted to `v*` tags: `release` (build and publish; no secrets) and `tap`
   (cask update). Add the `HOMEBREW_TAP_TOKEN` secret to `tap` only, never to `release` or the repository
   (fine-grained token, contents read/write on the Homebrew tap only).
3. Add a tag ruleset for `v*` so only maintainers can create or move release tags.

Each release:

1. Bump `CLIVersion.current` in `Packages/HeadsetKit/Sources/SennseiCLICore/CLIVersion.swift` and add a
   `## [x.y.z]` section to `CHANGELOG.md`.
2. Run `make check` and `make dist VERSION=x.y.z` locally from a clean tree.
3. Merge to `main`, then tag that commit: `git tag vx.y.z && git push origin vx.y.z`.
   Tags must be on `main`. A tag with a suffix (`v1.2.0-rc.1`) makes a GitHub prerelease and never touches the tap.
4. The `release` workflow tests, packages and publishes; the `tap` job (environment `tap`) then updates the cask.
