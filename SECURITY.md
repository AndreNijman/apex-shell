# Security policy

## Reporting a vulnerability

Report security problems privately through GitHub's private vulnerability
reporting: [open a report](https://github.com/AndreNijman/rime-shell/security/advisories/new).
Please don't open a public issue, pull request or discussion with exploit
details.

This repository is the desktop: the bar, the lock screen, notifications,
the clipboard history, the launcher, settings and the agent views. Problems in
the operating system underneath (the image, `rimed`, the agent runtime and its
sandbox, the credential broker, updates, Secure Boot) go to
[rime-os](https://github.com/AndreNijman/rime-os/security/advisories/new). If
you are not sure which one it is, report it in either; it will reach the same
person.

A useful report says what is affected, how to reproduce it, what an attacker
gains, and which build you saw it on: on Rime OS, the output of `bootc status`;
anywhere else, the rime-shell commit.

Reports go straight to the maintainer. One person maintains Rime, so there is
no guaranteed response time, but every report is read. Once a fix is
released, the advisory is published with credit to the reporter unless they
ask otherwise.

## Supported versions

Only `main` is supported. Rime OS vendors rime-shell's `main` into its image,
so a fix reaches Rime OS machines with the next image and `sudo rime update`.
On other distributions, `install.sh` installs `main`, and running it again
updates to the current `main`.

## Examples of what is in scope

- Getting past the lock screen, or anything that shows what is behind it
  while it is locked.
- The password field leaking the password or its characters (it should show
  only the length).
- Clipboard history or notifications exposing content they should not.
- Shell IPC or a script letting another program run commands it could not run
  otherwise.
