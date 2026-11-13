//! libxkbcommon.so.0 for linking Rune's keyboard handling (the xkbcommon
//! crate, which links it directly): a stand-in (deps/helpers) exporting every
//! function xkbcommon.h and xkbcommon-compose.h declare. The system's
//! libxkbcommon answers at run time.
const std = @import("std");
const helpers = @import("helpers");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.Optimize, "optimize", "Optimization mode (default ReleaseSafe)") orelse .safe;
    const xkbcommon = b.dependency("libxkbcommon", .{});
    var names: helpers.Names = .init(b);
    for ([_][]const u8{ "xkbcommon.h", "xkbcommon-compose.h" }) |header| {
        names.scanCHeader(helpers.read(b, xkbcommon, b.fmt("include/xkbcommon/{s}", .{header})), "xkb_");
    }
    const lib = helpers.library(b, target, optimize, "xkbcommon", 0, &names);
    b.installArtifact(lib);
    b.addNamedLazyPath("prefix", helpers.prefix(b, lib, null));
}
