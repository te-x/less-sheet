//! Baseline test — proves the toolchain/gate wiring. The planner owns this directory
//! from the first contract freeze; feature behavior tests land here.
const std = @import("std");

test "toolchain baseline" {
    try std.testing.expect(true);
}
