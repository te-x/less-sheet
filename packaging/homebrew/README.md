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

This argument used to rest on `--no-quarantine` being a literal Gatekeeper
bypass. **That flag no longer exists** — Homebrew 6 removed it, and there is no
occurrence left anywhere in `Library/Homebrew`. So the specific objection is
obsolete; whether an ad-hoc-signed app would be accepted today is an open
question we should not answer from memory, and notability remains a separate,
softer hurdle. What has not changed is that notarization is what a user
experiences as "it just installs", so the argument for a Developer ID survives
the flag that used to carry it.

## What users then run

```sh
brew tap <you>/tap
brew install --cask less-sheet
```

**Homebrew 6 always quarantines, and there is no opt-out.** It replaced the flag
with a user-approval model: the installed app carries `com.apple.quarantine`,
the user allows it once in System Settings → Privacy & Security → "Open Anyway",
and on a later upgrade Homebrew carries that approval forward — but *only* after
confirming the app's **designated requirement** is unchanged
(`Cask::Quarantine.inherit_user_approval!`).

That last clause is the one that costs us. An ad-hoc signature's designated
requirement is derived from the binary's cdhash, so it changes with **every
build** — the identity check cannot match, and approval is not inherited. Every
Homebrew upgrade therefore asks the user to approve again. A Developer ID
signature has a stable identity-based requirement, so approval carries forward
after the first time.

The `curl` one-liner remains the exception, and now the only one: Gatekeeper's
refusal keys on the **quarantine attribute, not the signature**, and `curl`
never sets it (measured: it writes `com.apple.provenance` and nothing else).

The cask deliberately does **not** strip the attribute itself in a `postflight`;
see the comment in the cask for why.

## Updating for a later release

Bump `version` and `sha256` and push. Homebrew picks it up on the user's next
`brew update`; `brew upgrade --cask less-sheet` then installs it.
