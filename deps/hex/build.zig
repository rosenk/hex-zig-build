//! Hex (anomalyco/hex at the commit build.zig.zon pins), built with
//! `cargo zigbuild` for Linux with the target's glibc, or for Windows x64
//! with MinGW, from a copy of its sources with one patch, to its build script
//! only (the program itself is Hex's own):
//!
//!   windows-gnu.patch  build.rs passes /DELAYLOAD and delayimp to MSVC
//!                      links only (deps/vulkan's vulkan-1 loads lazily),
//!                      and links HEX_WINDOWS_RES, the icon and version
//!                      resource compiled here with `zig rc`
//!
//! Its native dependencies come from the packages it depends on, each
//! handing over a prefix:
//!
//!   deps/transcribe  TRANSCRIBE_DIR for transcribe-cpp-sys (ggml, Vulkan)
//!   deps/openssl     Linux: OPENSSL_DIR, static libssl and libcrypto, for
//!                    openssl-sys (ureq's native-tls; SChannel on Windows)
//!   deps/alsa        Linux: libasound for alsa-sys (cpal), not pkg-config
//!   deps/xkbcommon   Linux: libxkbcommon for the xkbcommon crate (Rune)
//!
//! plus, on Linux, an empty libopenblas.so for the -lopenblas Hex's build.rs
//! passes there (its transcribe.cpp here uses no BLAS, so nothing is needed
//! from it and the linker drops it). Nothing comes from the build machine's
//! pkg-config database or -dev packages. On Windows, cpal and the rest use
//! the system's DLLs through the windows crates' import libraries.
//!
//! Options: -Dtarget (x86_64-linux-gnu.2.27, aarch64-linux-gnu.2.27,
//! x86_64-windows-gnu), -Doptimize (passed to every dependency, and mapped
//! onto cargo's profiles below), -Dcargo_target_dir (cargo's output; the root
//! passes its own target/), and `zig build -- …` arguments, passed to cargo.
//! `zig build -jN` also limits cargo's jobs (see cargo_jobs).
//! The named lazy path `hex` is the executable (hex.exe on Windows).
const std = @import("std");
const transcribe_build = @import("transcribe");
const helpers = @import("helpers");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.Optimize, "optimize", "Optimization mode (default ReleaseSafe)") orelse .safe;
    const target_dir = b.option(std.Build.LazyPath, "cargo_target_dir", "cargo's output directory") orelse b.path("target");

    const hex = b.dependency("hex", .{});
    const manifest = readManifest(b, hex);
    checkTranscribeRev(manifest);

    const t = target.result;
    const windows = t.os.tag == .windows;
    // Rust's target, and cargo-zigbuild's (which names the glibc on Linux).
    const rust_target: []const u8, const zigbuild_target: []const u8 = if (windows) blk: {
        if (t.cpu.arch != .x86_64 or !t.abi.isGnu()) @panic("Hex builds here for Windows as x86_64-windows-gnu");
        break :blk .{ "x86_64-pc-windows-gnu", "x86_64-pc-windows-gnu" };
    } else blk: {
        if (t.os.tag != .linux or !t.abi.isGnu()) @panic("Hex builds here for Linux with glibc (for example -Dtarget=x86_64-linux-gnu.2.27) or for x86_64-windows-gnu");
        const glibc = t.os.versionRange().gnuLibCVersion().?;
        const name = switch (t.cpu.arch) {
            .x86_64 => "x86_64-unknown-linux-gnu",
            .aarch64 => "aarch64-unknown-linux-gnu",
            else => @panic("Hex builds here for x86_64 and aarch64"),
        };
        break :blk .{ name, b.fmt("{s}.{d}.{d}", .{ name, glibc.major, glibc.minor }) };
    };

    const transcribe = b.dependency("transcribe", .{ .target = target, .optimize = optimize }).namedLazyPath("prefix");

    // cargo runs in a patched copy of Hex's sources; env(1) hands it the
    // prefixes, which exist only once the build runs, as absolute paths, and
    // cargo_jobs the job count of `zig build -jN`.
    const cargo = b.addSystemCommand(&.{ "sh", "-c", cargo_jobs, "sh", "env" });
    cargo.setName("cargo zigbuild");
    cargo.has_side_effects = true;
    cargo.setCwd(helpers.patched(b, hex, &.{"windows-gnu.patch"}));
    cargo.addDirectoryArg2(target_dir, .{ .prefix = "CARGO_TARGET_DIR=", .make_absolute = true });
    cargo.addArg(b.fmt("CARGO_ZIGBUILD_ZIG_PATH={s}", .{b.graph.zig_exe}));
    cargo.addDirectoryArg2(transcribe, .{ .prefix = "TRANSCRIBE_DIR=", .make_absolute = true });
    cargo.addArg("PKG_CONFIG_PATH=");
    if (windows) cargo.addFileArg2(windowsResources(b, hex, manifest), .{ .prefix = "HEX_WINDOWS_RES=", .make_absolute = true });
    const link_dir: ?std.Build.LazyPath = if (windows) null else linuxLinkDir(b, target, optimize);
    if (link_dir) |dir| cargo.addDirectoryArg2(dir, .{ .prefix = "PKG_CONFIG_LIBDIR=", .suffix = "/pkgconfig", .make_absolute = true });
    if (!windows) {
        // openssl-sys links deps/openssl statically: the executable needs no
        // libssl.so, whose soname differs between Debian 10-11 (1.1) and 12
        // and newer (3).
        const openssl = b.dependency("openssl", .{ .target = target, .optimize = optimize }).namedLazyPath("prefix");
        cargo.addDirectoryArg2(openssl, .{ .prefix = "OPENSSL_DIR=", .make_absolute = true });
        cargo.addArgs(&.{ "OPENSSL_STATIC=1", "OPENSSL_NO_VENDOR=1" });
    }
    cargo.addArgs(&.{ "cargo", "zigbuild", "--locked", "--bin", "hex", "--target", zigbuild_target });
    // Cargo's profile for the mode: Debug is the dev profile; the others are
    // the release profile, ReleaseSafe with overflow checks (not debug
    // assertions, which turn on Hex's development-only behaviour) and
    // ReleaseSmall optimizing for size.
    switch (optimize) {
        .debug => {},
        .safe => cargo.addArgs(&.{ "--release", "--config", "profile.release.overflow-checks=true" }),
        .fast => cargo.addArg("--release"),
        .small => cargo.addArgs(&.{ "--release", "--config", "profile.release.opt-level=\"s\"" }),
    }
    if (link_dir) |dir| addLinuxLinkConfig(b, cargo, rust_target, dir);
    cargo.addPassthruArgs();

    // The executable, as a path that carries the dependency on cargo.
    const exe = if (windows) "hex.exe" else "hex";
    const copy = b.addSystemCommand(&.{"cp"});
    copy.has_side_effects = true;
    copy.addDirectoryArg2(target_dir, .{ .suffix = b.fmt("/{s}/{s}/{s}", .{ rust_target, if (optimize == .debug) "debug" else "release", exe }), .make_absolute = true });
    copy.step.dependOn(&cargo.step);
    b.addNamedLazyPath("hex", copy.addOutputFileArg(exe));
}

/// `zig build -jN` limits how many of Zig's steps run at once, but reaches
/// neither build.zig nor the processes the steps start (ziglang/zig#20274:
/// no jobserver yet). cargo's step runs through this script, which takes -jN
/// from the command line of its parent, `zig build`'s runner, and hands it to
/// cargo as CARGO_BUILD_JOBS; cargo shares it with rustc, build scripts and
/// the cc crate through its jobserver. Without -jN cargo uses every core, and
/// `zig build -- -jN` still sets cargo's own. Zig's C and C++ compiles are not
/// covered: each uses every core until Zig passes -j on.
const cargo_jobs =
    \\j=$(tr '\0' '\n' <"/proc/$PPID/cmdline" 2>/dev/null | sed -n -e '/^--$/q' -e 's/^-j\([1-9][0-9]*\)$/\1/p' | tail -n 1)
    \\if [ -n "$j" ]; then export CARGO_BUILD_JOBS="$j"; fi
    \\exec "$@"
;

/// Linux: one directory for the libraries Hex links by name, the ALSA and
/// xkbcommon stand-ins and the empty libopenblas.so.
fn linuxLinkDir(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize) std.Build.LazyPath {
    const alsa = b.dependency("alsa", .{ .target = target, .optimize = optimize }).namedLazyPath("prefix");
    const xkbcommon = b.dependency("xkbcommon", .{ .target = target, .optimize = optimize }).namedLazyPath("prefix");

    const empty = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = false });
    empty.addCSourceFile(.{ .file = b.addWriteFiles().add("openblas.c", "typedef int hex_no_blas;\n"), .flags = &.{"-w"} });
    const openblas = b.addLibrary(.{ .name = "openblas", .linkage = .dynamic, .root_module = empty });

    const link = b.addWriteFiles();
    _ = link.addCopyDirectory(alsa.path(b, "lib"), "", .{});
    _ = link.addCopyDirectory(xkbcommon.path(b, "lib"), "", .{});
    _ = link.addCopyFile(openblas.getEmittedBin(), "libopenblas.so");
    return link.getDirectory();
}

/// Linux: alsa-sys finds libasound through pkg-config, so Cargo's
/// build-script override for its `links = "alsa"` names the library instead;
/// the xkbcommon crate and Hex's build.rs name theirs directly.
fn addLinuxLinkConfig(b: *std.Build, cargo: *std.Build.Step.Run, rust_target: []const u8, link_dir: std.Build.LazyPath) void {
    cargo.addArg("--config");
    cargo.addDirectoryArg2(link_dir, .{ .prefix = b.fmt("target.{s}.alsa.rustc-link-search=[\"native=", .{rust_target}), .suffix = "\"]", .make_absolute = true });
    cargo.addArgs(&.{ "--config", b.fmt("target.{s}.alsa.rustc-link-lib=[\"dylib=asound\"]", .{rust_target}) });
    cargo.addArg("--config");
    cargo.addDirectoryArg2(link_dir, .{ .prefix = b.fmt("target.{s}.rustflags=[\"-L\",\"native=", .{rust_target}), .suffix = "\"]", .make_absolute = true });
}

/// Windows: the icon and version resource Hex's build.rs embeds when it runs
/// on Windows (embed_windows_resources), from the same script, compiled with
/// `zig rc` for the patched build.rs to link on a cross build.
fn windowsResources(b: *std.Build, hex: *std.Build.Dependency, manifest: []const u8) std.Build.LazyPath {
    const version = packageVersion(manifest);
    // FILEVERSION's four numbers, as build.rs makes them: the first three
    // parts of the version split at '.' and '-', 0 for any that is no u16.
    var numeric: [4]u16 = @splat(0);
    var parts = std.mem.splitAny(u8, version, ".-");
    for (numeric[0..3]) |*number| number.* = std.fmt.parseInt(u16, parts.next() orelse break, 10) catch 0;

    const files = b.addWriteFiles();
    _ = files.addCopyFile(hex.path("resources/windows/hex.ico"), "hex.ico");
    const script = files.add("hex.rc", b.fmt(
        \\#include <winver.h>
        \\1 ICON "hex.ico"
        \\1 VERSIONINFO
        \\FILEVERSION {[n0]d},{[n1]d},{[n2]d},{[n3]d}
        \\PRODUCTVERSION {[n0]d},{[n1]d},{[n2]d},{[n3]d}
        \\FILEOS VOS_NT_WINDOWS32
        \\FILETYPE VFT_APP
        \\BEGIN
        \\  BLOCK "StringFileInfo"
        \\  BEGIN
        \\    BLOCK "040904B0"
        \\    BEGIN
        \\      VALUE "FileDescription", "Hex"
        \\      VALUE "ProductName", "Hex"
        \\      VALUE "FileVersion", "{[version]s}"
        \\      VALUE "ProductVersion", "{[version]s}"
        \\      VALUE "OriginalFilename", "hex.exe"
        \\      VALUE "InternalName", "hex"
        \\    END
        \\  END
        \\  BLOCK "VarFileInfo"
        \\  BEGIN
        \\    VALUE "Translation", 0x409, 1200
        \\  END
        \\END
        \\
    , .{ .n0 = numeric[0], .n1 = numeric[1], .n2 = numeric[2], .n3 = numeric[3], .version = version }));

    // The icon's relative path resolves against the script's directory.
    const rc = b.addSystemCommand(&.{ b.graph.zig_exe, "rc", "/fo" });
    rc.setName("zig rc hex.rc");
    const res = rc.addOutputFileArg("hex.res");
    rc.addFileArg(script);
    return res;
}

/// Hex's Cargo.toml.
fn readManifest(b: *std.Build, hex: *std.Build.Dependency) []const u8 {
    const path = hex.builder.root.joinString(b.allocator, "Cargo.toml") catch @panic("OOM");
    return std.Io.Dir.cwd().readFileAlloc(b.graph.io, path, b.allocator, .unlimited) catch |err|
        std.debug.panic("cannot read Hex's Cargo.toml: {t}", .{err});
}

/// The `version` of Cargo.toml's [package].
fn packageVersion(manifest: []const u8) []const u8 {
    const package = std.mem.indexOf(u8, manifest, "[package]\n") orelse @panic("Hex's Cargo.toml has no [package]");
    const key = "\nversion = \"";
    const start = (std.mem.indexOfPos(u8, manifest, package, key) orelse @panic("Hex's Cargo.toml has no package version")) + key.len;
    const end = std.mem.indexOfScalarPos(u8, manifest, start, '"') orelse @panic("Hex's Cargo.toml: unterminated version");
    return manifest[start..end];
}

/// deps/transcribe must build the transcribe.cpp revision Hex's Cargo.toml
/// patches in ([patch.crates-io] transcribe-cpp-sys); otherwise the Rust
/// bindings and the library would disagree. Move both pins together.
fn checkTranscribeRev(manifest: []const u8) void {
    const key = "\ntranscribe-cpp-sys = {";
    const start = (std.mem.indexOf(u8, manifest, key) orelse @panic("Hex's Cargo.toml no longer patches transcribe-cpp-sys")) + 1;
    const rest = manifest[start..];
    const line = rest[0 .. std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len];
    if (std.mem.indexOf(u8, line, transcribe_build.transcribe_commit) == null) {
        std.debug.panic(
            "Hex's Cargo.toml patches in another transcribe.cpp than deps/transcribe builds ({s}):\n  {s}\nMove deps/transcribe's transcribe_cpp dependency and transcribe_commit to Hex's rev.",
            .{ transcribe_build.transcribe_commit, line },
        );
    }
}
