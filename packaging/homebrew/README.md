# Homebrew tap — how to publish it

`Casks/less-sheet.rb` is a **template**, not a live cask. Homebrew resolves a tap
from a separate GitHub repository, so this cannot live in this workspace: it has
to be its own repo, named exactly `homebrew-<tap>`.

This workspace is never published (signed ARCH §1 non-goal), so nothing here
pushes anything. These are the steps for you to run, once, by hand.

## One-time: create the tap

```sh
# The repo name MUST start with `homebrew-`; the tap name is what follows it.
# Repo `github.com/<you>/homebrew-tap` becomes the tap `<you>/tap`.
mkdir homebrew-tap && cd homebrew-tap
git init && mkdir Casks
```

Copy `Casks/less-sheet.rb` in, fill the four placeholders (below), commit, and
push it to `github.com/<you>/homebrew-tap`. That is the whole tap — Homebrew
needs no manifest, no CI, and no registration.

## The four placeholders

| placeholder     | becomes                                                        |
| --------------- | -------------------------------------------------------------- |
| `VERSION`       | the release version, e.g. `0.1.0` — matches the repo `VERSION`  |
| `SHA256`        | the digest of the **.zip** artifact, from `dist/SHA256SUMS`     |
| `DOWNLOAD_BASE` | e.g. `https://github.com/<you>/less-sheet/releases/download/v0.1.0` |
| `HOMEPAGE`      | the project page                                                |

`make_release --cask-base <DOWNLOAD_BASE>` writes a filled copy to
`dist/less-sheet.rb` with the real version and digest already substituted — use
that rather than editing by hand. A wrong digest does not fail for you (your
Homebrew has the file cached); it fails for everyone installing afterwards, with
an error that reads like a corrupted download.

## What users then run

```sh
brew tap <you>/tap
brew install --cask less-sheet --no-quarantine
```

`--no-quarantine` is load-bearing while the app is unnotarized. Homebrew tags
downloads with `com.apple.quarantine`, and Gatekeeper's first-launch refusal keys
on **that attribute, not on the signature** — which is also why the `curl`
one-liner needs no flag and no dialog: `curl` never sets it.

Without the flag the install still succeeds, but the first launch is refused
until the user allows it in System Settings → Privacy & Security → "Open Anyway".

The cask deliberately does **not** strip the attribute itself in a `postflight`;
see the comment in the cask for why.

## Updating for a later release

Bump `version` and `sha256` and push. Homebrew picks it up on the user's next
`brew update`; `brew upgrade --cask less-sheet` then installs it.
