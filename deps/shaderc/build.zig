//! glslc, shaderc's GLSL to SPIR-V compiler, which ggml's Vulkan backend runs
//! while it builds (deps/transcribe: `vulkan-shaders-gen --glslc`). shaderc
//! v2026.1 (the version Hex's Debian build image builds), on deps/glslang,
//! deps/spirv-tools, and deps/spirv-headers at the revisions its DEPS file
//! pins. A build tool: build it for the machine running the build.
const std = @import("std");
const helpers = @import("helpers");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.Optimize, "optimize", "Optimization mode (default ReleaseSafe)") orelse .safe;

    const shaderc = b.dependency("shaderc", .{});
    const glslang = b.dependency("glslang", .{ .target = target, .optimize = optimize }).artifact("glslang");
    const spirv_tools = b.dependency("spirv_tools", .{ .target = target, .optimize = optimize }).artifact("SPIRV-Tools");
    const spirv = b.dependency("spirv_headers", .{}).namedLazyPath("include");

    const version = b.addWriteFiles();
    _ = version.add("build-version.inc",
        \\"shaderc v2026.1\n"
        \\"spirv-tools v2026.1 fbe4f3ad913c44fe8700545f8ffe35d1382b7093\n"
        \\"glslang 16.2.0 f0bd0257c308b9a26562c1a30c4748a0219cc951\n"
        \\
    );

    const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .link_libcpp = true });
    mod.linkLibrary(glslang);
    mod.linkLibrary(spirv_tools);
    mod.addIncludePath(version.getDirectory());
    mod.addIncludePath(spirv);
    mod.addIncludePath(shaderc.path("libshaderc/include"));
    mod.addIncludePath(shaderc.path("libshaderc_util/include"));
    mod.addIncludePath(shaderc.path("glslc/src"));
    for ([_][]const u8{ "libshaderc/src", "libshaderc_util/src", "glslc/src" }) |dir| {
        mod.addCSourceFiles(.{
            .root = shaderc.path(dir),
            .files = helpers.sourcesIn(b, shaderc, dir, ".cc", &.{}),
            .flags = &.{ "-std=c++17", "-w", "-DENABLE_HLSL", "-DNDEBUG" },
        });
    }

    b.installArtifact(b.addExecutable(.{ .name = "glslc", .root_module = mod }));
}
