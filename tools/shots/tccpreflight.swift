// Screen Recording preflight for tools/shots/capture_shots — asks WHETHER the
// permission is granted without EVER prompting for it.
//
// This distinction is the whole file. `screencapture` (and CGRequestScreenCaptureAccess)
// pop the system permission dialog on first use; the standing rule on this
// project is that tooling never fires a TCC prompt at the author — it detects the
// missing grant and tells him the exact click instead. CGPreflightScreenCaptureAccess
// is the query-only call: it returns the current state and never prompts.
//
// exit 0 = granted (window capture may proceed)
// exit 1 = not granted (the tool prints the grant instructions and stops)
import CoreGraphics
exit(CGPreflightScreenCaptureAccess() ? 0 : 1)
