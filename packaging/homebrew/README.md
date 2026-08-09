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

## Why a tap, and not just `brew install --cask less-sheet`

Homebrew does not discover anything. A tap is a public GitHub repo named
`homebrew-<something>` full of Ruby files; `brew tap you/tap` clones it, and from
then on the cask resolves locally. No registry, no submission, no approval —
which is exactly why this route works today.

Installing with **no tap at all** requires the cask to live in the official
`homebrew/cask` repo, and **less-sheet is ineligible while it is ad-hoc signed**.
From <https://docs.brew.sh/Acceptable-Casks>, a cask:

> must not require System Integrity Protection or Gatekeeper to be disabled or
> bypassed

`--no-quarantine` is precisely a Gatekeeper bypass, so the cask below cannot be
submitted as-is. There is a second, softer hurdle too — notability, judged case
by case — but the Gatekeeper rule is a hard one, and it is the one we control.

So notarization (a Developer ID, ~$99/yr) buys more than smoother first-launch:
it is what makes official Homebrew distribution possible at all, i.e. the
difference between "tap my repo first" and "it is just there, like any other
app". When that happens, delete `--no-quarantine` from the docs below, drop the
comment in the cask, and the submission becomes possible.

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
