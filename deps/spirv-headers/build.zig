//! The SPIR-V headers and grammar files, shared by deps/glslc (SPIRV-Tools,
//! glslang, shaderc) and deps/transcribe (ggml's Vulkan backend). The named
//! lazy path `include` is their include/ directory.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const headers = b.dependency("spirv_headers", .{});
    b.addNamedLazyPath("include", headers.path("include"));
    b.installDirectory(.{ .source_dir = headers.path("include"), .install_dir = .header, .install_subdir = "" });
}
