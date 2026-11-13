//! Builds Hex (deps/hex) for Linux with an older glibc than the build machine
//! has: 2.27 by default, so Debian 10, Ubuntu 18.04 and newer. Speech runs
//! on the GPU where the system has a Vulkan 1.2 loader and driver (Debian 11,
//! Ubuntu 20.04 and newer), on the CPU elsewhere. Every package under deps/ declares its own
//! dependencies in its build.zig.zon; see README.md.
//!
//!   zig build                                    # zig-out/bin/hex, x86_64, glibc 2.27
//!   zig build -Dtarget=aarch64-linux-gnu.2.27    # ARM64
//!   zig build -Dtarget=x86_64-windows-gnu        # zig-out/bin/hex.exe, Windows x64
//!   zig build -Doptimize=ReleaseFast             # Debug, ReleaseSafe (default), ReleaseFast, ReleaseSmall
//!   zig build -j4                                # at most 4 steps at once, and cargo -j4
//!   zig build -- --features onnx-benchmark       # extra cargo arguments
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{
        .os_tag = .linux,
        .abi = .gnu,
        .glibc_version = .{ .major = 2, .minor = 27, .patch = 0 },
        // The architecture's baseline, not the build machine's CPU: the
        // executable runs on other machines.
        .cpu_model = .baseline,
    } });
    // One optimization mode for everything: every deps/ package passes it on.
    const optimize = b.option(std.builtin.Optimize, "optimize", "Optimization mode (default ReleaseSafe)") orelse .safe;

    const hex = b.dependency("hex", .{
        .target = target,
        .optimize = optimize,
        .cargo_target_dir = b.path("target"),
    });
    const exe = if (target.result.os.tag == .windows) "hex.exe" else "hex";
    b.getInstallStep().dependOn(&b.addInstallBinFile(hex.namedLazyPath("hex"), exe).step);
}
