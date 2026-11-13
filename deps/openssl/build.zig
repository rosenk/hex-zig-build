//! OpenSSL (upstream release, build.zig.zon) as static libcrypto and libssl,
//! for openssl-sys in Hex (ureq's native-tls), so the executable needs no
//! libssl.so of any version. The named lazy path `prefix` is an OPENSSL_DIR:
//! lib/libcrypto.a, lib/libssl.a, include/openssl/.
//!
//! OpenSSL's own Configure (perl from mise) decides the configuration, the
//! sources, and their flags for the target; openssl.pl reads its configdata
//! and runs the generators its Makefile would (headers from .in templates,
//! perlasm assembly). Zig compiles everything; nothing runs make.
//! OPENSSLDIR is /etc/ssl.
//!
//! Every step's inputs are only these files, the release, the target, and
//! the options, so a build after the first compiles none of OpenSSL again:
//! the generator gets CC through env(1), not through the Run step's
//! environment, which would hash the whole process environment and rerun
//! (and recompile everything after it) whenever any variable differs.
const std = @import("std");

const options = [_][]const u8{
    "no-shared", "no-tests", "no-apps",   "no-docs",
    "no-module", "no-dso",   "no-engine", "no-afalgeng",
    "--openssldir=/etc/ssl",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.Optimize, "optimize", "Optimization mode (default ReleaseSafe)") orelse .safe;
    const perl = b.option([]const u8, "perl", "Perl for OpenSSL's Configure and generators") orelse "perl";
    const src = b.dependency("openssl_src", .{});
    const os_target = configureTarget(target.result);

    // What to compile, from Configure, cached per target under .zig-cache.
    // The configure phase reruns when openssl.pl changes.
    b.dependOnFileContents(b.path("openssl.pl"));
    const plan_dir = b.root.joinString(b.allocator, b.fmt(".zig-cache/openssl-plan/{s}", .{os_target})) catch @panic("OOM");
    var plan_argv: std.ArrayList([]const u8) = .empty;
    plan_argv.appendSlice(b.allocator, &.{ perl, b.root.joinString(b.allocator, "openssl.pl") catch @panic("OOM"), "plan", src.builder.root.joinString(b.allocator, "") catch @panic("OOM"), plan_dir, os_target }) catch @panic("OOM");
    plan_argv.appendSlice(b.allocator, &options) catch @panic("OOM");
    const plan = b.run(plan_argv.items);

    // The generated headers and sources.
    // perlasm asks the compiler which instructions its assembler takes.
    const generate = b.addSystemCommand(&.{ "env", b.fmt("CC={s} cc", .{b.graph.zig_exe}), perl });
    generate.setName("openssl.pl generate");
    generate.addFileArg(b.path("openssl.pl"));
    generate.addArg("generate");
    generate.addDirectoryArg(src.path(""));
    const gen = generate.addOutputDirectoryArg("gen");
    generate.addArg(os_target);
    generate.addArgs(&options);

    const crypto = library(b, target, optimize, "crypto", "libcrypto", plan, src, gen);
    const ssl = library(b, target, optimize, "ssl", "libssl", plan, src, gen);
    for ([_]*std.Build.Step.Compile{ crypto, ssl }) |lib| {
        lib.installHeadersDirectory(src.path("include/openssl"), "openssl", .{});
        lib.installHeadersDirectory(gen.path(b, "include/openssl"), "openssl", .{});
        b.installArtifact(lib);
    }

    const prefix = b.addWriteFiles();
    _ = prefix.addCopyFile(crypto.getEmittedBin(), "lib/libcrypto.a");
    _ = prefix.addCopyFile(ssl.getEmittedBin(), "lib/libssl.a");
    _ = prefix.addCopyDirectory(src.path("include/openssl"), "include/openssl", .{ .exclude_extensions = &.{".in"} });
    _ = prefix.addCopyDirectory(gen.path(b, "include/openssl"), "include/openssl", .{});
    b.addNamedLazyPath("prefix", prefix.getDirectory());
}

/// Configure's target name for a Zig target.
fn configureTarget(t: std.Target) []const u8 {
    return switch (t.os.tag) {
        .linux => switch (t.cpu.arch) {
            .x86_64 => "linux-x86_64",
            .aarch64 => "linux-aarch64",
            else => @panic("no OpenSSL target for this Linux architecture"),
        },
        .windows => switch (t.cpu.arch) {
            .x86_64 => "mingw64",
            else => @panic("no OpenSSL target for this Windows architecture"),
        },
        else => @panic("no OpenSSL target for this OS"),
    };
}

/// lib<name>.a from the plan's records for `product` (libcrypto, libssl).
fn library(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, name: []const u8, product: []const u8, plan: []const u8, src: *std.Build.Dependency, gen: std.Build.LazyPath) *std.Build.Step.Compile {
    const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .pic = true });
    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, &.{
        "-w",
        // OpenSSL's stacks free their elements through the generic
        // `void (*)(void *)` (OPENSSL_sk_pop_free calling X509_free and the
        // like), which UBSan's function-type check traps on in ReleaseSafe.
        // The call is sound on every ABI; the other checks stay on.
        "-fno-sanitize=function",
        "-DOPENSSLDIR=\"/etc/ssl\"",
        "-DENGINESDIR=\"\"",
        "-DMODULESDIR=\"\"",
    }) catch @panic("OOM");
    var src_files: std.ArrayList([]const u8) = .empty;
    var gen_files: std.ArrayList([]const u8) = .empty;

    var lines = std.mem.tokenizeScalar(u8, plan, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const kind = fields.next() orelse continue;
        if (!std.mem.eql(u8, fields.next() orelse continue, product)) continue;
        const value = fields.next() orelse @panic("malformed OpenSSL plan line");
        if (std.mem.eql(u8, kind, "define")) {
            flags.append(b.allocator, b.fmt("-D{s}", .{value})) catch @panic("OOM");
        } else if (std.mem.eql(u8, kind, "include")) {
            mod.addIncludePath(place(b, value, src, gen));
        } else if (std.mem.eql(u8, kind, "source")) {
            const list = if (std.mem.startsWith(u8, value, "src/")) &src_files else &gen_files;
            list.append(b.allocator, value[4..]) catch @panic("OOM");
        } else std.debug.panic("unknown OpenSSL plan record {s}", .{kind});
    }
    if (src_files.items.len == 0) std.debug.panic("OpenSSL's plan names no sources for {s}", .{product});
    mod.addCSourceFiles(.{ .root = src.path(""), .files = src_files.items, .flags = flags.items });
    if (gen_files.items.len > 0) mod.addCSourceFiles(.{ .root = gen, .files = gen_files.items, .flags = flags.items });
    return b.addLibrary(.{ .name = name, .linkage = .static, .root_module = mod });
}

fn place(b: *std.Build, path: []const u8, src: *std.Build.Dependency, gen: std.Build.LazyPath) std.Build.LazyPath {
    const rel = path[4..];
    if (std.mem.startsWith(u8, path, "src/")) return src.path(rel);
    if (std.mem.startsWith(u8, path, "gen/")) return gen.path(b, rel);
    std.debug.panic("OpenSSL plan path {s} is neither src/ nor gen/", .{path});
}
