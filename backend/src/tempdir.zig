//! The ONE resolver for the directory every EPHEMERAL core temp file lives in.
//!
//! Three subsystems create private, unlinked-on-create, mode-0600 scratch
//! files: the gzip inflate-checkpoint spill (src/source.zig), the network spool
//! (src/net_source.zig), and — from the sort-by-column slice — the sort's runs,
//! permutation, and inverse mapping (src/sort.zig). ARCH-sort-by-column
//! decision 4 chose "the EXISTING platform-temp spill resolver" over a new
//! caller-supplied cache-dir knob; this module IS that resolver, so the choice
//! of directory (and the discipline around it) is made in exactly one place
//! instead of being re-derived per subsystem.
//!
//! The frozen `srt_temp_single_source` test points `setForTest` at an unusable
//! directory and requires BOTH the gzip checkpoint spill AND a sort build to
//! notice, so a subsystem that hard-codes its own path fails the gate.

const std = @import("std");

/// The platform default when nothing is overridden.
pub const default_dir: []const u8 = "/tmp";

/// TEST-ONLY override (see contracts/api.zig `tempSpillDirSetForTest`).
/// Process-wide, because the temp directory is a process-wide property and the
/// gzip Source resolves it without a Document in hand. The borrowed slice must
/// outlive every later temp-file creation.
var override_dir: ?[]const u8 = null;

/// Install (or, with null, remove) the process-wide override.
pub fn setForTest(dir: ?[]const u8) void {
    override_dir = dir;
}

/// THE RESOLVER. Every ephemeral temp path in the core is built from this.
pub fn resolve() []const u8 {
    return override_dir orelse default_dir;
}
