//! SPIRV-Tools with its optimizer (SPIRV-Tools-opt) as one static library,
//! `SPIRV-Tools`, with its public headers (spirv-tools/*.h, *.hpp) installed
//! for the packages that link it (deps/glslang, deps/shaderc). Depends on
//! deps/spirv-headers for the SPIR-V grammar. The grammar tables come from
//! SPIRV-Tools' own Python generators, as in its CMake build (python3 on
//! PATH, or -Dpython=…).
const std = @import("std");
const helpers = @import("helpers");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.Optimize, "optimize", "Optimization mode (default ReleaseSafe)") orelse .safe;
    const python = b.option([]const u8, "python", "Python 3 interpreter for the table generators") orelse "python3";

    const tools = b.dependency("spirv_tools", .{});
    const spirv = b.dependency("spirv_headers", .{}).namedLazyPath("include");

    const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .link_libcpp = true });
    for (generate(b, tools, spirv, python)) |dir| mod.addIncludePath(dir);
    mod.addIncludePath(tools.path(""));
    mod.addIncludePath(tools.path("include"));
    mod.addIncludePath(spirv);
    mod.addIncludePath(spirv.path(b, "spirv/unified1"));
    for ([_][]const u8{ "source", "source/util", "source/val", "source/opt" }) |dir| {
        mod.addCSourceFiles(.{
            .root = tools.path(dir),
            .files = helpers.sourcesIn(b, tools, dir, ".cpp", &.{ "mimalloc.cpp", "pch_source.cpp", "pch_source_opt.cpp" }),
            .flags = &.{ "-std=c++17", "-w", "-DSPIRV_LINUX", "-DSPIRV_COLOR_TERMINAL", "-DNDEBUG" },
        });
    }

    const lib = b.addLibrary(.{ .name = "SPIRV-Tools", .root_module = mod });
    lib.installHeadersDirectory(tools.path("include"), "", .{ .include_extensions = &.{ ".h", ".hpp" } });
    b.installArtifact(lib);
}

/// What SPIRV-Tools' CMake build generates with Python: the grammar tables,
/// the extended instruction set headers, and the generator registry; plus the
/// version string. Returns the directories that hold them.
fn generate(b: *std.Build, tools: *std.Build.Dependency, spirv: std.Build.LazyPath, python: []const u8) []const std.Build.LazyPath {
    const grammar = "spirv/unified1/";

    const tables = b.addSystemCommand(&.{ python, "-I" });
    tables.addFileArg(tools.path("utils/ggt.py"));
    _ = tables.addPrefixedOutputFileArg("--core-tables-body-output=", "core_tables_body.inc");
    const tables_dir = tables.addPrefixedOutputFileArg("--core-tables-header-output=", "core_tables_header.inc").dirname();
    tables.addPrefixedFileArg("--spirv-core-grammar=", spirv.path(b, grammar ++ "spirv.core.grammar.json"));
    for ([_][2][]const u8{
        .{ "", "extinst.glsl.std.450.grammar.json" },
        .{ "", "extinst.opencl.std.100.grammar.json" },
        .{ "CLDEBUG100_", "extinst.opencl.debuginfo.100.grammar.json" },
        .{ "SHDEBUG100_", "extinst.nonsemantic.shader.debuginfo.100.grammar.json" },
        .{ "", "extinst.spv-amd-shader-explicit-vertex-parameter.grammar.json" },
        .{ "", "extinst.spv-amd-shader-trinary-minmax.grammar.json" },
        .{ "", "extinst.spv-amd-gcn-shader.grammar.json" },
        .{ "", "extinst.spv-amd-shader-ballot.grammar.json" },
        .{ "", "extinst.debuginfo.grammar.json" },
        .{ "", "extinst.nonsemantic.clspvreflection.grammar.json" },
        .{ "", "extinst.nonsemantic.vkspreflection.grammar.json" },
        .{ "TOSA_", "extinst.tosa.001000.1.grammar.json" },
        .{ "", "extinst.arm.motion-engine.100.grammar.json" },
    }) |ext| {
        tables.addPrefixedFileArg(b.fmt("--extinst={s},", .{ext[0]}), spirv.path(b, b.fmt(grammar ++ "{s}", .{ext[1]})));
    }

    const registry = b.addSystemCommand(&.{ python, "-I" });
    registry.addFileArg(tools.path("utils/generate_registry_tables.py"));
    registry.addPrefixedFileArg("--xml=", spirv.path(b, "spirv/spir-v.xml"));
    const registry_dir = registry.addPrefixedOutputFileArg("--generator-output=", "generators.inc").dirname();

    // update_build_version.py would describe whatever git checkout the build
    // runs in; name the pinned revision instead.
    const version = b.addWriteFiles();
    _ = version.add("build-version.inc",
        \\"v2026.1", "SPIRV-Tools v2026.1 fbe4f3ad913c44fe8700545f8ffe35d1382b7093"
        \\
    );

    var dirs: std.ArrayList(std.Build.LazyPath) = .empty;
    dirs.appendSlice(b.allocator, &.{ tables_dir, registry_dir, version.getDirectory() }) catch @panic("OOM");
    for ([_][2][]const u8{
        .{ "DebugInfo", "extinst.debuginfo.grammar.json" },
        .{ "OpenCLDebugInfo100", "extinst.opencl.debuginfo.100.grammar.json" },
        .{ "NonSemanticShaderDebugInfo100", "extinst.nonsemantic.shader.debuginfo.100.grammar.json" },
    }) |lang| {
        const header = b.addSystemCommand(&.{ python, "-I" });
        header.addFileArg(tools.path("utils/generate_language_headers.py"));
        header.addPrefixedFileArg("--extinst-grammar=", spirv.path(b, b.fmt(grammar ++ "{s}", .{lang[1]})));
        const out = header.addPrefixedOutputFileArg("--extinst-output-path=", b.fmt("{s}.h", .{lang[0]}));
        dirs.append(b.allocator, out.dirname()) catch @panic("OOM");
    }
    return dirs.items;
}
