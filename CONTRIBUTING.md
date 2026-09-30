# Contributing to Rime Shell

Thanks for helping. Rime Shell is the desktop of
[Rime OS](https://github.com/AndreNijman/rime-os): the Rime OS image vendors
this repository's `main`, so a change merged here reaches every Rime OS machine
with the next image. It also runs on other distributions through `install.sh`.

## Where a change belongs

| Change | Repository |
|---|---|
| The bar, notch, Dashboard, lock screen, launcher, settings, notifications, clipboard, agent views | this one |
| The image, `rimed` and the `rime` CLI, the agent runtime, the login screen, the installer | [rime-os](https://github.com/AndreNijman/rime-os) |
| rimeos.com | [rime-website](https://github.com/AndreNijman/rime-website) |

## Issues

Use the issue forms. Say which compositor you run (Hyprland, niri or labwc) and
your monitor setup; many bugs depend on both. Security problems do not go in
issues: see [SECURITY.md](SECURITY.md).

## Pull requests

- Branch from `main`, one topic per branch, and open a pull request against
  `main`.
- Three checks must pass: `Repo Structure Sanity`,
  `Arch Linux — Dependency & Lint Check` and `NixOS — Flake & Package Check`.
  The branch must be up to date with `main` when it merges, and pull requests
  merge with a merge commit.
- CI on a pull request from a first-time contributor waits until a maintainer
  approves the run.
- If your change needs a matching Rime OS change, give both branches the same
  name. Rime OS's pull request checks look for a rime-shell branch with the
  name of theirs.

### The release note

Every pull request fills in the `## Release note` section of the template:
one or two sentences about what someone using Rime will notice, or `none`.
That section is the only part copied onto the release page on rimeos.com, and
the pull request title becomes the page title, so write both for users. Leave
out people's names, machine names and quotes.

### Commits

- [Conventional Commits](https://www.conventionalcommits.org/): `feat:`,
  `fix:`, `docs:`, `refactor:`, `perf:`, `test:`, `chore:`.
- One logical change per commit. Say why in the body, not only what.
- No AI attribution in commits, pull request text, release notes or source
  files.

## Testing

The tests live in `tests/`, and [.github/workflows/ci.yml](.github/workflows/ci.yml)
runs all of them:

- `tests/check-*.sh` are static checks over the source. Run the ones that
  cover what you touched; they are fast.
- `shellcheck -S warning -x tests/*.sh` is CI's lint step. Run it before
  pushing any change to a test script.
- `tests/*-test.js` are Node unit tests for the JavaScript in `src/`.
- `tests/run-*.sh` start the real shell under a headless compositor
  (`tests/lib/headless.sh`) with stand-ins for the system services they need.
  They need `quickshell` and the compositor installed, and skip when a tool is
  missing.

A fixed bug comes with a test that fails without the fix. Change the UI on
your own resolution, and on a second monitor or scale factor when the change
touches layout.

## Licence

Rime Shell is released under the [MIT licence](LICENSE), and contributions are
accepted under the same licence. It started as a fork of
[Brain_Shell](https://github.com/Brainitech/Brain_Shell) by Brainitech, also
MIT. `src/shapes/material/` is third-party code under the Apache License 2.0;
see [its README](src/shapes/material/README.md).

Taking part here means following the [Code of Conduct](CODE_OF_CONDUCT.md).
