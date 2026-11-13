//! libasound.so.2 for linking cpal's ALSA backend (alsa-sys): a stand-in
//! (deps/helpers) exporting every function alsa-lib's public headers declare.
//! The system's libasound answers at run time, with its plugins (PulseAudio,
//! PipeWire), which a statically linked alsa-lib could not load.
//!
//! The stand-in carries alsa-lib's symbol versions (src/Versions.in.in), so
//! the executable asks for e.g. snd_pcm_hw_params_get_channels@ALSA_0.9.0rc4.
//! Unversioned, the dynamic linker would bind the old ALSA_0.9 variants, whose
//! hw_params getters have another ABI (cpal then reads zero channels).
const std = @import("std");
const helpers = @import("helpers");

/// include/Makefile.am's alsainclude_HEADERS.
const headers = [_][]const u8{
    "asoundef.h",         "global.h",   "input.h",       "output.h",
    "error.h",            "conf.h",     "control.h",     "control_plugin.h",
    "control_external.h", "pcm.h",      "pcm_old.h",     "timer.h",
    "pcm_plugin.h",       "pcm_rate.h", "pcm_extplug.h", "pcm_ioplug.h",
    "rawmidi.h",          "ump.h",      "ump_msg.h",     "hwdep.h",
    "mixer.h",            "mixer_abst.h", "seq_event.h", "seq.h",
    "seqmid.h",           "seq_midi_event.h", "topology.h", "use-case.h",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.Optimize, "optimize", "Optimization mode (default ReleaseSafe)") orelse .safe;
    const alsa = b.dependency("alsa_lib", .{});
    var names: helpers.Names = .init(b);
    for (headers) |header| names.scanCHeader(helpers.read(b, alsa, b.fmt("include/{s}", .{header})), "snd_");
    const versions = versionScript(b, helpers.read(b, alsa, "src/Versions.in.in"), &names);
    const lib = helpers.library(b, target, optimize, "asound", 2, &names);
    lib.setVersionScript(b.addWriteFiles().add("Versions", versions));
    b.installArtifact(lib);
    b.addNamedLazyPath("prefix", helpers.prefix(b, lib, null));
}

/// src/Versions as alsa-lib's build makes it from Versions.in.in: no symbol
/// prefix, and every PCM, timer, rawmidi, and sequencer node in (the
/// template's only conditionals, all true for a full alsa-lib), so the
/// preprocessor lines just go. Every name the script lists by name goes into
/// `names` too: lld refuses a version for a symbol the library lacks, and the
/// real libasound exports them all (some, like snd_lib_vlog, under names the
/// public headers only reach through macros).
fn versionScript(b: *std.Build, template: []const u8, names: *helpers.Names) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, template, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "#")) continue;
        const text = std.mem.replaceOwned(u8, b.allocator, line, "@SYMBOL_PREFIX@", "") catch @panic("OOM");
        const entry = std.mem.trim(u8, text, " \t\r");
        if (std.mem.endsWith(u8, entry, ";") and std.mem.indexOfAny(u8, entry, "*{}: ") == null) names.add(entry[0 .. entry.len - 1]);
        out.print(b.allocator, "{s}\n", .{text}) catch @panic("OOM");
    }
    return out.items;
}
