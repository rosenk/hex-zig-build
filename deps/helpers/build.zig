//! Build helpers the deps/ packages share: listing an upstream directory's
//! sources, reading an upstream file while configuring, and link-time
//! stand-ins of shared libraries the system provides at run time
//! (deps/alsa, deps/xkbcommon, deps/vulkan). A stand-in is a shared library with
//! the real soname whose functions are empty, generated from the names an
//! upstream header or export list declares. An executable linked against one
//! records only the soname, so the system's own library answers at run time
//! and the build needs no -dev package. A function the program calls that the
//! stand-in lacks fails the link instead of passing silently. Only functions:
//! a library whose users reference its data symbols needs the real thing.
const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b;
}

/// The function names a stand-in exports.
pub const Names = struct {
    b: *std.Build,
    set: std.StringArrayHashMapUnmanaged(void) = .empty,

    pub fn init(b: *std.Build) Names {
        return .{ .b = b };
    }

    pub fn add(self: *Names, name: []const u8) void {
        self.set.put(self.b.allocator, name, {}) catch @panic("OOM");
    }

    /// Every `<name_prefix>name(` in a C header: a function declaration (or a
    /// function-like macro, whose extra stub costs nothing).
    pub fn scanCHeader(self: *Names, text: []const u8, name_prefix: []const u8) void {
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, text, i, name_prefix)) |start| {
            i = start + name_prefix.len;
            if (start > 0 and isIdent(text[start - 1])) continue;
            var end = i;
            while (end < text.len and isIdent(text[end])) end += 1;
            var next = end;
            while (next < text.len and (text[next] == ' ' or text[next] == '\t')) next += 1;
            if (next < text.len and text[next] == '(') self.add(text[start..end]);
            i = end;
        }
    }

    /// The names after EXPORTS in a Windows module-definition file.
    pub fn scanDef(self: *Names, text: []const u8) void {
        var exports = false;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw[0 .. std.mem.indexOfScalar(u8, raw, ';') orelse raw.len], " \t\r");
            if (line.len == 0) continue;
            if (std.mem.eql(u8, line, "EXPORTS")) {
                exports = true;
                continue;
            }
            if (exports) self.add(line[0 .. std.mem.indexOfAny(u8, line, " \t") orelse line.len]);
        }
    }

    fn source(self: *const Names) []const u8 {
        if (self.set.count() == 0) @panic("no symbols found");
        var out: std.ArrayList(u8) = .empty;
        for (self.set.keys()) |name| {
            out.print(self.b.allocator, "void {s}(void) {{}}\n", .{name}) catch @panic("OOM");
        }
        return out.items;
    }

    fn isIdent(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }
};

/// Reads `path` inside a fetched dependency while the build is configured.
pub fn read(b: *std.Build, dep: *std.Build.Dependency, path: []const u8) []const u8 {
    const full = dep.builder.root.joinString(b.allocator, path) catch @panic("OOM");
    return std.Io.Dir.cwd().readFileAlloc(b.graph.io, full, b.allocator, .unlimited) catch |err|
        std.debug.panic("cannot read {s}: {t}", .{ path, err });
}

/// The files directly in `dir` of `dep` that end in `ext`, sorted, minus
/// `skip` and tests (`*_test*`).
pub fn sourcesIn(b: *std.Build, dep: *std.Build.Dependency, dir: []const u8, ext: []const u8, skip: []const []const u8) []const []const u8 {
    const path = dep.builder.root.joinString(b.allocator, dir) catch @panic("OOM");
    var handle = std.Io.Dir.cwd().openDir(b.graph.io, path, .{ .iterate = true }) catch |err|
        std.debug.panic("cannot open {s}: {t}", .{ path, err });
    defer handle.close(b.graph.io);
    var files: std.ArrayList([]const u8) = .empty;
    var it = handle.iterate();
    entries: while (it.next(b.graph.io) catch |err| std.debug.panic("cannot list {s}: {t}", .{ path, err })) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ext)) continue;
        if (std.mem.indexOf(u8, entry.name, "_test") != null) continue;
        for (skip) |name| if (std.mem.eql(u8, entry.name, name)) continue :entries;
        files.append(b.allocator, b.dupe(entry.name)) catch @panic("OOM");
    }
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lessThan(_: void, l: []const u8, r: []const u8) bool {
            return std.mem.lessThan(u8, l, r);
        }
    }.lessThan);
    return files.items;
}

/// lib<name>.so.<major>, exporting `names` as empty functions.
pub fn library(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, name: []const u8, major: u32, names: *const Names) *std.Build.Step.Compile {
    const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = false });
    mod.addCSourceFile(.{
        .file = b.addWriteFiles().add(b.fmt("{s}.c", .{name}), names.source()),
        .flags = &.{ "-w", "-fno-builtin" },
    });
    return b.addLibrary(.{
        .name = name,
        .linkage = .dynamic,
        .version = .{ .major = major, .minor = 0, .patch = 0 },
        .root_module = mod,
    });
}

/// A prefix for the packages that link the stand-in: lib/lib<name>.so (the
/// name -l<name> finds; the soname inside stays lib<name>.so.<major>) and,
/// when given, the headers as include/.
pub fn prefix(b: *std.Build, lib: *std.Build.Step.Compile, headers: ?std.Build.LazyPath) std.Build.LazyPath {
    const files = b.addWriteFiles();
    _ = files.addCopyFile(lib.getEmittedBin(), b.fmt("lib/lib{s}.so", .{lib.name}));
    if (headers) |dir| _ = files.addCopyDirectory(dir, "include", .{});
    return files.getDirectory();
}

/// `dep`'s files with `patch_files` (relative to the calling package)
/// applied in order, as a directory. Each is a unified diff in `git diff`'s
/// form (text before the first `--- ` is a description), read and applied
/// while the build is configured, without patch(1) or git; each hunk must
/// match exactly, near the line it names, or the build stops and says which.
/// The patched files are written, everything else is copied.
pub fn patched(b: *std.Build, dep: *std.Build.Dependency, patch_files: []const []const u8) std.Build.LazyPath {
    var files: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    for (patch_files) |patch_file| {
        b.dependOnFileContents(b.path(patch_file));
        const patch_path = b.root.joinString(b.allocator, patch_file) catch @panic("OOM");
        const text = std.Io.Dir.cwd().readFileAlloc(b.graph.io, patch_path, b.allocator, .unlimited) catch |err|
            std.debug.panic("cannot read {s}: {t}", .{ patch_path, err });
        var lines = Lines{ .text = text };
        var changed: usize = 0;
        while (lines.peek()) |line| {
            if (!std.mem.startsWith(u8, line, "--- ")) {
                _ = lines.next();
                continue;
            }
            _ = lines.next();
            const plus = lines.next() orelse std.debug.panic("{s}: `--- ` without `+++ `", .{patch_path});
            if (!std.mem.startsWith(u8, plus, "+++ ")) std.debug.panic("{s}: `--- ` without `+++ `", .{patch_path});
            const path = stripPrefix(plus[4..]);
            // A file an earlier patch changed takes this one's on top.
            const original = if (std.mem.eql(u8, stripPrefix(line[4..]), "/dev/null"))
                ""
            else
                files.get(path) orelse read(b, dep, path);
            files.put(b.allocator, path, applyHunks(b, patch_path, path, original, &lines)) catch @panic("OOM");
            changed += 1;
        }
        if (changed == 0) std.debug.panic("{s} changes no file", .{patch_path});
    }

    const tree = b.addWriteFiles();
    copyExcept(b, tree, dep, "", files.keys());
    for (files.keys(), files.values()) |path, contents| _ = tree.add(path, contents);
    return tree.getDirectory();
}

/// Lines of a patch, each without its newline.
const Lines = struct {
    text: []const u8,
    pos: usize = 0,

    fn peek(l: *Lines) ?[]const u8 {
        if (l.pos >= l.text.len) return null;
        const end = std.mem.indexOfScalarPos(u8, l.text, l.pos, '\n') orelse l.text.len;
        return l.text[l.pos..end];
    }

    fn next(l: *Lines) ?[]const u8 {
        const line = l.peek() orelse return null;
        l.pos += line.len + 1;
        return line;
    }
};

/// `a/path` and `b/path` name `path`.
fn stripPrefix(name: []const u8) []const u8 {
    const path = std.mem.trimEnd(u8, name[0 .. std.mem.indexOfScalar(u8, name, '\t') orelse name.len], " ");
    if (std.mem.startsWith(u8, path, "a/") or std.mem.startsWith(u8, path, "b/")) return path[2..];
    return path;
}

/// The file's hunks (the `@@` blocks that follow) applied to `original`.
fn applyHunks(b: *std.Build, patch_path: []const u8, path: []const u8, original: []const u8, lines: *Lines) []const u8 {
    var file: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, original, '\n');
    while (it.next()) |line| file.append(b.allocator, line) catch @panic("OOM");
    // A file that ends in a newline splits into a last, empty element.
    const trailing_newline = original.len == 0 or original[original.len - 1] == '\n';
    if (trailing_newline) _ = file.pop();
    var newline_at_end = trailing_newline;

    var offset: isize = 0;
    while (lines.peek()) |header| {
        if (!std.mem.startsWith(u8, header, "@@ ")) break;
        _ = lines.next();
        const range = HunkRange.parse(header) orelse std.debug.panic("{s}: bad hunk header {s}", .{ patch_path, header });
        const old_start = range.old_start;
        var old: std.ArrayList([]const u8) = .empty;
        var new: std.ArrayList([]const u8) = .empty;
        // The header's counts say where the hunk ends.
        while (old.items.len < range.old_count or new.items.len < range.new_count) {
            const line = lines.next() orelse std.debug.panic("{s}: hunk {s} is cut short", .{ patch_path, header });
            if (line.len == 0) {
                // An empty context line whose space an editor dropped.
                old.append(b.allocator, "") catch @panic("OOM");
                new.append(b.allocator, "") catch @panic("OOM");
            } else switch (line[0]) {
                ' ' => {
                    old.append(b.allocator, line[1..]) catch @panic("OOM");
                    new.append(b.allocator, line[1..]) catch @panic("OOM");
                },
                '-' => old.append(b.allocator, line[1..]) catch @panic("OOM"),
                '+' => new.append(b.allocator, line[1..]) catch @panic("OOM"),
                '\\' => newline_at_end = false,
                else => std.debug.panic("{s}: unexpected line in hunk {s}: {s}", .{ patch_path, header, line }),
            }
        }
        if (lines.peek()) |line| if (line.len > 0 and line[0] == '\\') {
            newline_at_end = false;
            _ = lines.next();
        };
        // Where the hunk says, or the nearest place its old lines match.
        // A hunk that only adds lines names the line it adds after.
        const first_line = if (range.old_count == 0) old_start else old_start -| 1;
        const expected: usize = @intCast(@max(0, @as(isize, @intCast(first_line)) + offset));
        const at = findLines(file.items, old.items, expected) orelse
            std.debug.panic("{s}: hunk {s} does not apply to {s}", .{ patch_path, header, path });
        file.replaceRange(b.allocator, at, old.items.len, new.items) catch @panic("OOM");
        offset += @as(isize, @intCast(new.items.len)) - @as(isize, @intCast(old.items.len));
    }
    var out = std.mem.join(b.allocator, "\n", file.items) catch @panic("OOM");
    if (newline_at_end and file.items.len > 0) out = b.fmt("{s}\n", .{out});
    return out;
}

/// `@@ -start[,count] +start[,count] @@`; a count left out is 1.
const HunkRange = struct {
    old_start: usize,
    old_count: usize,
    new_count: usize,

    fn parse(header: []const u8) ?HunkRange {
        if (!std.mem.startsWith(u8, header, "@@ -")) return null;
        const rest = header[4..];
        const plus = std.mem.indexOf(u8, rest, " +") orelse return null;
        const end = std.mem.indexOfPos(u8, rest, plus + 2, " @@") orelse return null;
        const old = range(rest[0..plus]) orelse return null;
        const new = range(rest[plus + 2 .. end]) orelse return null;
        return .{ .old_start = old[0], .old_count = old[1], .new_count = new[1] };
    }

    fn range(text: []const u8) ?[2]usize {
        const comma = std.mem.indexOfScalar(u8, text, ',');
        const start = std.fmt.parseInt(usize, text[0 .. comma orelse text.len], 10) catch return null;
        const count = if (comma) |c| std.fmt.parseInt(usize, text[c + 1 ..], 10) catch return null else 1;
        return .{ start, count };
    }
};

/// The index nearest `expected` where `needle` matches `haystack` exactly.
fn findLines(haystack: []const []const u8, needle: []const []const u8, expected: usize) ?usize {
    if (needle.len > haystack.len) return null;
    const last = haystack.len - needle.len;
    var distance: usize = 0;
    while (distance <= last + expected) : (distance += 1) {
        for ([_]isize{ 1, -1 }) |sign| {
            const at = @as(isize, @intCast(expected)) + sign * @as(isize, @intCast(distance));
            if (at < 0 or at > last) continue;
            const i: usize = @intCast(at);
            if (matches(haystack[i..][0..needle.len], needle)) return i;
            if (distance == 0) break;
        }
    }
    return null;
}

fn matches(a: []const []const u8, b: []const []const u8) bool {
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

/// Copies `dir` of `dep` into `tree`, but not the files in `skip`: whole
/// directories where none is inside, file by file along the way to them.
fn copyExcept(b: *std.Build, tree: *std.Build.Step.WriteFile, dep: *std.Build.Dependency, dir: []const u8, skip: []const []const u8) void {
    const full = dep.builder.root.joinString(b.allocator, dir) catch @panic("OOM");
    var handle = std.Io.Dir.cwd().openDir(b.graph.io, full, .{ .iterate = true }) catch |err|
        std.debug.panic("cannot open {s}: {t}", .{ full, err });
    defer handle.close(b.graph.io);
    var it = handle.iterate();
    while (it.next(b.graph.io) catch |err| std.debug.panic("cannot list {s}: {t}", .{ full, err })) |entry| {
        const rel = if (dir.len == 0) b.dupe(entry.name) else b.fmt("{s}/{s}", .{ dir, entry.name });
        var skipped = false;
        var inside = false;
        for (skip) |path| {
            if (std.mem.eql(u8, path, rel)) skipped = true;
            if (path.len > rel.len and std.mem.startsWith(u8, path, rel) and path[rel.len] == '/') inside = true;
        }
        if (skipped) continue;
        if (inside) {
            copyExcept(b, tree, dep, rel, skip);
        } else if (entry.kind == .directory) {
            _ = tree.addCopyDirectory(dep.path(rel), rel, .{});
        } else {
            _ = tree.addCopyFile(dep.path(rel), rel);
        }
    }
}
