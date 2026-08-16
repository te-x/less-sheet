cask "less-sheet" do
  # Filled by `tools/release/make_release --cask-base <url>`, which reads the
  # version and the REAL sha256 straight out of SHA256SUMS. Do not hand-edit the
  # digest: a wrong one does not fail for you, it fails for everyone who installs
  # after you, with an error that looks like a corrupted download.
  version "VERSION"
  sha256 "SHA256"

  url "DOWNLOAD_BASE/less-sheet-#{version}-macos-arm64.zip"
  name "less-sheet"
  desc "Read-only viewer for spreadsheet-sized CSV, plain, gzipped or over HTTP"
  homepage "HOMEPAGE"

  # Apple silicon only, and the app genuinely refuses to start below its floor
  # rather than starting and misbehaving, so these are real constraints.
  depends_on arch: :arm64
  # macOS 26. A bare symbol, NOT ">= :tahoe": the string-comparison form is
  # deprecated and warns on every `brew tap`. It still means "or newer" —
  # Homebrew parses this argument with comparator ">=" by default
  # (Library/Homebrew/cask/dsl/depends_on.rb), so the floor is unchanged.
  depends_on macos: :tahoe

  app "less-sheet.app"

  # NO postflight that strips com.apple.quarantine.
  #
  # It would work, and it would make `brew install --cask less-sheet` a clean
  # one-liner with no flag. It is deliberately not here: silently disabling a
  # Gatekeeper check on someone's machine, because they installed your app, is
  # not a decision this file gets to make for them.
  #
  # There is no flag for it any more either: Homebrew 6 REMOVED
  # `--no-quarantine`. Casks are always quarantined, and the user approves once
  # in System Settings -> Privacy & Security -> "Open Anyway". Homebrew carries
  # that approval into later upgrades (Quarantine.inherit_user_approval!) but
  # only while the app's DESIGNATED REQUIREMENT is unchanged — and an ad-hoc
  # signature's requirement is derived from the cdhash, so it changes on every
  # build and every upgrade asks again.
  #
  # Notarizing is what fixes that: a Developer ID requirement is identity-based
  # and stable, so the approval is inherited. Nothing else here changes.

  zap trash: [
    "~/Library/Preferences/com.lesssheet.LessSheet.plist",
    "~/Library/Saved Application State/com.lesssheet.LessSheet.savedState",
  ]
end
