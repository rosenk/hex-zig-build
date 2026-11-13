//! glslang with its HLSL front end and SPIR-V back end as one static library,
//! `glslang`, with its headers (glslang/…, SPIRV/…) installed for the
//! packages that link it (deps/shaderc). Depends on deps/spirv-tools, whose
//! optimizer the SPIR-V back end runs (ENABLE_OPT).
const std = @import("std");
const helpers = @import("helpers");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.Optimize, "optimize", "Optimization mode (default ReleaseSafe)") orelse .safe;

    const glslang = b.dependency("glslang", .{});
    const spirv_tools = b.dependency("spirv_tools", .{ .target = target, .optimize = optimize }).artifact("SPIRV-Tools");

    const build_info = b.addWriteFiles();
    const build_info_h = build_info.add("glslang/build_info.h", glslang_build_info);

    const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .link_libcpp = true });
    mod.addIncludePath(build_info.getDirectory());
    mod.addIncludePath(glslang.path(""));
    mod.linkLibrary(spirv_tools);
    for ([_][]const u8{
        "glslang/MachineIndependent",
        "glslang/MachineIndependent/preprocessor",
        "glslang/GenericCodeGen",
        "glslang/HLSL",
        "glslang/ResourceLimits",
        "glslang/OSDependent/Unix",
        "SPIRV",
    }) |dir| {
        mod.addCSourceFiles(.{
            .root = glslang.path(dir),
            .files = helpers.sourcesIn(b, glslang, dir, ".cpp", &.{"pch.cpp"}),
            .flags = &.{ "-std=c++17", "-w", "-DENABLE_HLSL", "-DENABLE_OPT=1", "-DNDEBUG" },
        });
    }

    const lib = b.addLibrary(.{ .name = "glslang", .root_module = mod });
    const headers: []const []const u8 = &.{ ".h", ".hpp", ".hpp11" };
    lib.installHeadersDirectory(glslang.path("glslang"), "glslang", .{ .include_extensions = headers });
    lib.installHeadersDirectory(glslang.path("SPIRV"), "SPIRV", .{ .include_extensions = headers });
    lib.installHeader(build_info_h, "glslang/build_info.h");
    b.installArtifact(lib);
}

/// glslang's build_info.h for 16.2.0 (CHANGES.md), as its build_info.py writes it.
const glslang_build_info =
    \\#ifndef GLSLANG_BUILD_INFO
    \\#define GLSLANG_BUILD_INFO
    \\#define GLSLANG_VERSION_MAJOR 16
    \\#define GLSLANG_VERSION_MINOR 2
    \\#define GLSLANG_VERSION_PATCH 0
    \\#define GLSLANG_VERSION_FLAVOR ""
    \\#define GLSLANG_VERSION_GREATER_THAN(major, minor, patch) \
    \\    ((GLSLANG_VERSION_MAJOR) > (major) || ((major) == GLSLANG_VERSION_MAJOR && \
    \\    ((GLSLANG_VERSION_MINOR) > (minor) || ((minor) == GLSLANG_VERSION_MINOR && \
    \\     (GLSLANG_VERSION_PATCH) > (patch)))))
    \\#define GLSLANG_VERSION_GREATER_OR_EQUAL_TO(major, minor, patch) \
    \\    ((GLSLANG_VERSION_MAJOR) > (major) || ((major) == GLSLANG_VERSION_MAJOR && \
    \\    ((GLSLANG_VERSION_MINOR) > (minor) || ((minor) == GLSLANG_VERSION_MINOR && \
    \\     (GLSLANG_VERSION_PATCH >= (patch))))))
    \\#define GLSLANG_VERSION_LESS_THAN(major, minor, patch) \
    \\    ((GLSLANG_VERSION_MAJOR) < (major) || ((major) == GLSLANG_VERSION_MAJOR && \
    \\    ((GLSLANG_VERSION_MINOR) < (minor) || ((minor) == GLSLANG_VERSION_MINOR && \
    \\     (GLSLANG_VERSION_PATCH) < (patch)))))
    \\#define GLSLANG_VERSION_LESS_OR_EQUAL_TO(major, minor, patch) \
    \\    ((GLSLANG_VERSION_MAJOR) < (major) || ((major) == GLSLANG_VERSION_MAJOR && \
    \\    ((GLSLANG_VERSION_MINOR) < (minor) || ((minor) == GLSLANG_VERSION_MINOR && \
    \\     (GLSLANG_VERSION_PATCH <= (patch))))))
    \\#endif
    \\
;
