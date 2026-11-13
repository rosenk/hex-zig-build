//! transcribe.cpp and its ggml (CPU and Vulkan backends) as one static
//! library, built by Zig instead of transcribe.cpp's CMake. The named lazy
//! path `prefix` is the install layout transcribe-cpp-sys reads through
//! TRANSCRIBE_DIR:
//!
//!   lib/libtranscribe.a, lib/transcribe-link.json, lib/libvulkan.a,
//!   include/transcribe.h, include/transcribe/*.h
//!
//! Depends on deps/vulkan (headers, and the libvulkan.a ggml-vulkan links,
//! which loads the system's loader on first use), deps/spirv-headers, and
//! deps/shaderc (built for the machine running the build, to compile the
//! shaders).
//!
//! The configuration matches the one Hex's Linux release passes to the CMake
//! build (.cargo/config.toml, scripts/build-linux.sh): a static library,
//! GGML_NATIVE=OFF (x86-64-v3 kernels on x86_64), no system BLAS, no OpenMP,
//! llamafile sgemm, and Vulkan shaders for f32, f16, q8_0, and q5_0 weights
//! without MUL_MAT_ID. The transcribe.cpp revision must match Hex's Cargo.toml
//! ([patch.crates-io] transcribe-cpp-sys rev); deps/hex checks it.
const std = @import("std");

pub const transcribe_commit = "bcb639faa4c74a2300ba19e30360cb2355b1663a";
const ggml_version = "0.26.0";

/// GGML_VULKAN_SHADER_TYPES / GGML_VULKAN_MUL_MAT_ID=OFF in .cargo/config.toml.
const shader_filter = [_][]const u8{ "--types", "f32,f16,q8_0,q5_0", "--no-mul-mat-id" };

/// The shader extensions the pinned glslc (deps/shaderc) supports, as
/// ggml-vulkan's CMake finds them by compiling vulkan-shaders/feature-tests.
const glslc_features = [_][]const u8{
    "-DGGML_VULKAN_COOPMAT_GLSLC_SUPPORT",
    "-DGGML_VULKAN_COOPMAT2_GLSLC_SUPPORT",
    "-DGGML_VULKAN_INTEGER_DOT_GLSLC_SUPPORT",
    "-DGGML_VULKAN_BFLOAT16_GLSLC_SUPPORT",
    "-DGGML_VULKAN_FLOAT_E4M3_GLSLC_SUPPORT",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.Optimize, "optimize", "Optimization mode (default ReleaseSafe)") orelse .safe;
    const tr = b.dependency("transcribe_cpp", .{});
    const vulkan = b.dependency("vulkan", .{ .target = target, .optimize = optimize }).namedLazyPath("prefix");
    const spirv_headers = b.dependency("spirv_headers", .{}).namedLazyPath("include");
    const glslc = b.dependency("shaderc", .{ .target = b.graph.host, .optimize = optimize }).artifact("glslc");

    // GGML_NATIVE=OFF on x86_64: ggml's default instruction sets (SSE4.2,
    // AVX, AVX2, BMI2, FMA, F16C), whatever CPU the build runs on.
    var lib_target = target;
    if (target.result.cpu.arch == .x86_64) {
        var query = target.query;
        query.cpu_model = .baseline;
        for ([_]std.Target.x86.Feature{ .sse4_2, .avx, .avx2, .bmi2, .fma, .f16c }) |feature| {
            query.cpu_features_add.addFeature(@intFromEnum(feature));
        }
        lib_target = b.resolveTargetQuery(query);
    }

    // No UBSan outside Debug, as in the CMake Release build Hex ships: in
    // ReleaseSafe Zig would put overflow and bounds traps into ggml's kernels
    // (tinyBLAS, ops), which costs the CPU backend its speed.
    const mod = b.createModule(.{
        .target = lib_target,
        .optimize = optimize,
        .sanitize_c = if (optimize == .debug) null else .off,
        .link_libc = true,
        .link_libcpp = true,
        .pic = true,
    });

    const generated = b.addWriteFiles();
    _ = generated.add("ggml-version.h", "#pragma once\n#define GGML_VERSION \"" ++ ggml_version ++ "\"\n#define GGML_COMMIT \"" ++ transcribe_commit[0..8] ++ "\"\n");
    mod.addIncludePath(generated.getDirectory());
    mod.addIncludePath(tr.path("include"));
    mod.addIncludePath(tr.path("src"));
    mod.addIncludePath(tr.path("ggml/include"));
    mod.addIncludePath(tr.path("ggml/src"));
    mod.addIncludePath(tr.path("ggml/src/ggml-cpu"));
    mod.addIncludePath(vulkan.path(b, "include"));
    mod.addIncludePath(spirv_headers);

    const common = [_][]const u8{
        "-w",
        // ggml registers typed kernels (dequantize_row_q8_0 and the like)
        // under generic pointer types (ggml_to_float_t, …) and calls them
        // through those, which UBSan's function-type check traps on in
        // Debug. Sound on every ABI; the other checks stay on there.
        "-fno-sanitize=function",
        "-DNDEBUG",
        "-DGGML_SCHED_MAX_COPIES=4",
        "-DGGML_USE_CPU",
        "-DGGML_USE_VULKAN",
        "-DGGML_USE_LLAMAFILE",
        "-DGGML_USE_CPU_REPACK",
        "-DTRANSCRIBE_STATIC",
        "-DTRANSCRIBE_BUILD",
        "-DTRANSCRIBE_COMMIT=\"" ++ transcribe_commit ++ "\"",
        "-DMINIZ_NO_INFLATE_APIS",
        "-DMINIZ_NO_STDIO",
        "-DMINIZ_NO_TIME",
        "-DMINIZ_NO_ZLIB_COMPATIBLE_NAMES",
    } ++ glslc_features;
    // The platform defines ggml's and transcribe's CMake add.
    const platform: []const []const u8 = switch (target.result.os.tag) {
        .linux => &.{ "-D_GNU_SOURCE", "-D_XOPEN_SOURCE=600" },
        .windows => &.{ "-D_CRT_SECURE_NO_WARNINGS", "-D_USE_MATH_DEFINES" },
        else => @panic("transcribe.cpp builds here for Linux and Windows"),
    };
    // -O3 as in the CMake Release build, where Zig passes -O2 for ReleaseFast
    // and ReleaseSafe; clang takes the last -O. ReleaseSmall keeps Zig's -Os.
    const opt_level: []const []const u8 = switch (optimize) {
        .fast, .safe => &.{"-O3"},
        .debug, .small => &.{},
    };
    const c_flags = std.mem.concat(b.allocator, []const u8, &.{ &.{"-std=gnu11"}, &common, platform, opt_level }) catch @panic("OOM");
    const cxx_flags = std.mem.concat(b.allocator, []const u8, &.{ &.{"-std=gnu++17"}, &common, platform, opt_level }) catch @panic("OOM");

    // ggml-base and ggml (ggml/src/CMakeLists.txt).
    mod.addCSourceFiles(.{ .root = tr.path("ggml/src"), .files = &.{ "ggml.c", "ggml-alloc.c", "ggml-quants.c" }, .flags = c_flags });
    mod.addCSourceFiles(.{ .root = tr.path("ggml/src"), .files = &.{
        "ggml.cpp",          "ggml-backend.cpp",     "ggml-backend-meta.cpp", "ggml-opt.cpp",
        "ggml-threading.cpp", "gguf.cpp",            "ggml-backend-dl.cpp",   "ggml-backend-reg.cpp",
    }, .flags = cxx_flags });

    // ggml-cpu (ggml/src/ggml-cpu/CMakeLists.txt).
    mod.addCSourceFiles(.{ .root = tr.path("ggml/src/ggml-cpu"), .files = &.{ "ggml-cpu.c", "quants.c" }, .flags = c_flags });
    mod.addCSourceFiles(.{ .root = tr.path("ggml/src/ggml-cpu"), .files = &.{
        "ggml-cpu.cpp",      "repack.cpp",     "hbm.cpp",        "traits.cpp",
        "amx/amx.cpp",       "amx/mmq.cpp",    "tiled/tiled.cpp", "tiled/tiled-kernel.cpp",
        "binary-ops.cpp",    "unary-ops.cpp",  "vec.cpp",        "ops.cpp",
        "llamafile/sgemm.cpp",
    }, .flags = cxx_flags });
    const arch_dir = switch (target.result.cpu.arch) {
        .x86_64 => "x86",
        .aarch64 => "arm",
        else => @panic("transcribe.cpp builds for x86_64 and aarch64 here"),
    };
    mod.addCSourceFile(.{ .file = tr.path(b.fmt("ggml/src/ggml-cpu/arch/{s}/quants.c", .{arch_dir})), .flags = c_flags });
    mod.addCSourceFile(.{ .file = tr.path(b.fmt("ggml/src/ggml-cpu/arch/{s}/repack.cpp", .{arch_dir})), .flags = cxx_flags });

    // ggml-vulkan: vulkan-shaders-gen, built for this machine, compiles each
    // shader with glslc into a C++ source of SPIR-V arrays.
    const shaders = "ggml/src/ggml-vulkan/vulkan-shaders";
    const gen_mod = b.createModule(.{ .target = b.graph.host, .optimize = optimize, .link_libc = true, .link_libcpp = true });
    gen_mod.addCSourceFile(.{ .file = tr.path(shaders ++ "/vulkan-shaders-gen.cpp"), .flags = &([_][]const u8{ "-std=gnu++17", "-w" } ++ glslc_features) });
    const gen = b.addExecutable(.{ .name = "vulkan-shaders-gen", .root_module = gen_mod });

    const header = b.addRunArtifact(gen);
    header.addArg("--output-dir");
    _ = header.addOutputDirectoryArg("spv");
    header.addArg("--target-hpp");
    const hpp = header.addOutputFileArg("ggml-vulkan-shaders.hpp");
    header.addArgs(&shader_filter);
    mod.addIncludePath(hpp.dirname());

    for (sourcesIn(b, tr, shaders, ".comp")) |name| {
        const run = b.addRunArtifact(gen);
        run.addArg("--glslc");
        run.addArtifactArg(glslc);
        run.addArg("--source");
        run.addFileArg(tr.path(b.fmt(shaders ++ "/{s}", .{name})));
        run.addArg("--output-dir");
        _ = run.addOutputDirectoryArg("spv");
        run.addArgs(&.{ "--target-hpp", "ggml-vulkan-shaders.hpp", "--target-cpp" });
        const cpp = run.addOutputFileArg(b.fmt("{s}.cpp", .{name}));
        run.addArgs(&shader_filter);
        // SPIR-V byte arrays: nothing to optimize.
        mod.addCSourceFile(.{ .file = cpp, .flags = &.{ "-std=gnu++17", "-O0", "-w" } });
    }
    mod.addCSourceFiles(.{ .root = tr.path("ggml/src/ggml-vulkan"), .files = &.{
        "ggml-vulkan.cpp", "ggml-vulkan-buffers.cpp", "ggml-vulkan-debug.cpp",
    }, .flags = cxx_flags });

    // transcribe itself: the add_library(transcribe ...) list of src/CMakeLists.txt.
    for (transcribeSources(b, tr)) |file| {
        mod.addCSourceFile(.{ .file = tr.path(b.fmt("src/{s}", .{file})), .flags = if (std.mem.endsWith(u8, file, ".c")) c_flags else cxx_flags });
    }

    const lib = b.addLibrary(.{ .name = "transcribe", .linkage = .static, .root_module = mod });
    lib.installHeader(tr.path("include/transcribe.h"), "transcribe.h");
    lib.installHeadersDirectory(tr.path("include/transcribe"), "transcribe", .{});
    b.installArtifact(lib);

    // The link manifest transcribe-cpp-sys reads (cmake/transcribe-install.cmake).
    // The C++ runtime is Zig's libc++, which `-lstdc++` selects at the final
    // link. Vulkan is the system's at run time: libvulkan.so.1 on Linux, and
    // vulkan-1.dll on Windows, loaded on first use by deps/vulkan's library
    // (libvulkan.a, libvulkan-1.a), which needs dlopen (-ldl) on Linux.
    //
    // transcribe-cpp-sys links `libraries` as static and `system_libs` as
    // dylib (-Bdynamic, so a .so only), so on Linux libvulkan.a goes after
    // transcribe in `libraries`. On Windows the dylib lookup takes
    // vulkan-1.lib, the import-library name deps/vulkan also installs.
    const libraries: []const u8, const system_libs: []const u8 = switch (target.result.os.tag) {
        .windows => .{ "\"transcribe\"", "\"vulkan-1\", \"stdc++\"" },
        else => .{ "\"transcribe\", \"vulkan\"", "\"stdc++\", \"m\", \"dl\", \"pthread\"" },
    };
    const manifest = b.addWriteFiles().add("transcribe-link.json", b.fmt(
        \\{{
        \\  "version": "0.4.1",
        \\  "commit": "
    ++ transcribe_commit ++
        \\",
        \\  "shared": false,
        \\  "backend_dl": false,
        \\  "module_dir": null,
        \\  "backends": ["cpu", "vulkan"],
        \\  "metal_embed": false,
        \\  "include_dir": "include",
        \\  "lib_dir": "lib",
        \\  "libraries": [{s}],
        \\  "library_paths": [],
        \\  "system_libs": [{s}],
        \\  "frameworks": [],
        \\  "link_flags": []
        \\}}
        \\
    , .{ libraries, system_libs }));
    b.getInstallStep().dependOn(&b.addInstallFile(manifest, "lib/transcribe-link.json").step);

    const prefix = b.addWriteFiles();
    _ = prefix.addCopyDirectory(vulkan, "", .{});
    _ = prefix.addCopyFile(lib.getEmittedBin(), "lib/libtranscribe.a");
    _ = prefix.addCopyFile(manifest, "lib/transcribe-link.json");
    _ = prefix.addCopyFile(tr.path("include/transcribe.h"), "include/transcribe.h");
    _ = prefix.addCopyDirectory(tr.path("include/transcribe"), "include/transcribe", .{});
    b.addNamedLazyPath("prefix", prefix.getDirectory());
}

/// The sources between `add_library(transcribe` and its `)` in src/CMakeLists.txt.
fn transcribeSources(b: *std.Build, tr: *std.Build.Dependency) []const []const u8 {
    const text = std.Io.Dir.cwd().readFileAlloc(b.graph.io, tr.builder.root.joinString(b.allocator, "src/CMakeLists.txt") catch @panic("OOM"), b.allocator, .unlimited) catch |err|
        std.debug.panic("cannot read transcribe.cpp's src/CMakeLists.txt: {t}", .{err});
    const start = std.mem.indexOf(u8, text, "add_library(transcribe\n") orelse @panic("src/CMakeLists.txt: no add_library(transcribe");
    var files: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text[start + "add_library(transcribe\n".len ..], '\n');
    list: while (lines.next()) |raw| {
        // CMake comments (`#` to the end of the line) may hold parentheses.
        var line = raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len];
        const close = std.mem.indexOfScalar(u8, line, ')');
        if (close) |i| line = line[0..i];
        var tokens = std.mem.tokenizeAny(u8, line, " \t\r");
        while (tokens.next()) |token| {
            if (std.mem.endsWith(u8, token, ".cpp") or std.mem.endsWith(u8, token, ".c")) {
                files.append(b.allocator, token) catch @panic("OOM");
            }
        }
        if (close != null) break :list;
    } else @panic("src/CMakeLists.txt: unterminated add_library(transcribe");
    if (files.items.len < 50) std.debug.panic("src/CMakeLists.txt: only {d} transcribe sources; has the list moved?", .{files.items.len});
    return files.items;
}

/// The files directly in `dir` of `dep` that end in `ext`, sorted.
fn sourcesIn(b: *std.Build, dep: *std.Build.Dependency, dir: []const u8, ext: []const u8) []const []const u8 {
    const path = dep.builder.root.joinString(b.allocator, dir) catch @panic("OOM");
    var handle = std.Io.Dir.cwd().openDir(b.graph.io, path, .{ .iterate = true }) catch |err|
        std.debug.panic("cannot open {s}: {t}", .{ path, err });
    defer handle.close(b.graph.io);
    var files: std.ArrayList([]const u8) = .empty;
    var it = handle.iterate();
    while (it.next(b.graph.io) catch |err| std.debug.panic("cannot list {s}: {t}", .{ path, err })) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ext)) files.append(b.allocator, b.dupe(entry.name)) catch @panic("OOM");
    }
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lessThan(_: void, l: []const u8, r: []const u8) bool {
            return std.mem.lessThan(u8, l, r);
        }
    }.lessThan);
    return files.items;
}
