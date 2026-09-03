# Forwarding the old site address

The landing page and the release downloads live on the main repository (`te-x/less-sheet`):
Pages serves `site/` at <https://te-x.github.io/less-sheet/> through
`.github/workflows/deploy-site.yml`, and every release is published under that repository's Releases.

The old address, <https://te-x.github.io/less-sheet-site/>, was shared before the move, so the
`less-sheet-site` repository stays alive with exactly these two files as its whole content:

- `index.html` — forwards the front page (meta refresh + canonical + script, carrying query and fragment).
- `404.html` — forwards any deep link to the same path under the new site.

## Switching it on (once, after the main repository's Pages site is live)

1. Confirm <https://te-x.github.io/less-sheet/> serves the page (the main repository must be public, with
   Pages set to deploy from GitHub Actions).
2. Make these two files the only content of `less-sheet-site`'s `main` branch and push. If that
   repository is being recreated from scratch, push them as its first commit.
3. Pages on `less-sheet-site`: source `main`, folder `/` (root).
4. Check: the old URL lands on the new page; an old deep link such as `/less-sheet-site/assets/logo.svg`
   lands on the new site's copy.

GitHub Pages cannot send a real HTTP redirect, so old direct download URLs under
`github.com/te-x/less-sheet-site/releases/...` are not covered by this: they keep working only while
that repository still carries the release. The page itself, and every link on it, points at the main
repository's releases.
