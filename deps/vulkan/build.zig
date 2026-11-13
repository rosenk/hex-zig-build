//! Vulkan for building against: the Vulkan headers, and a static library
//! with the loader's exports (loader/vulkan-1.def) whose functions load the
//! system's loader on their first call. The named lazy path `prefix` holds
//! include/ and lib/:
//!
//!   Linux:   lib/libvulkan.a, loading libvulkan.so.1 (x86_64, aarch64)
//!   Windows: lib/libvulkan-1.a (also as vulkan-1.lib), loading vulkan-1.dll
//!            (x86_64)
//!
//! The loader comes with the graphics driver, and a missing or old one must
//! not stop Hex at launch: Hex's MSVC build delay-loads vulkan-1.dll for that
//! (Hex #1240); on Linux, Hex's release needs the libvulkan1 package
//! installed, and a Vulkan 1.0 loader (Debian 9, Ubuntu 16.04) would stop it
//! before main, since it lacks Vulkan 1.1's vkGetPhysicalDeviceFeatures2 and
//! Rust binds every symbol at start. Zig's linker has no /DELAYLOAD, so
//! each function is a thunk that resolves itself through LoadLibrary and
//! GetProcAddress (dlopen and dlsym on Linux), as a delay-load import would.
//!
//! On Linux the library also does at start what Hex does on Windows before
//! ggml touches Vulkan (src/windows/vulkan.rs): without a Vulkan 1.2
//! loader, which ggml needs, it sets GGML_DISABLE_VULKAN, so ggml never
//! registers its Vulkan backend and speech runs on the CPU. Otherwise ggml
//! would ask a 1.0 loader for vkEnumerateInstanceVersion and call the null
//! pointer it gets.
const std = @import("std");
const helpers = @import("helpers");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.Optimize, "optimize", "Optimization mode (default ReleaseSafe)") orelse .safe;
    const headers = b.dependency("vulkan_headers", .{});
    const loader = b.dependency("vulkan_loader", .{});
    var names: helpers.Names = .init(b);
    names.scanDef(helpers.read(b, loader, "loader/vulkan-1.def"));

    const t = target.result;
    const abi: Abi = switch (t.os.tag) {
        .linux => switch (t.cpu.arch) {
            .x86_64 => .linux_x86_64,
            .aarch64 => .linux_aarch64,
            else => @panic("the lazy Vulkan library is for x86_64 and aarch64 Linux"),
        },
        .windows => switch (t.cpu.arch) {
            .x86_64 => .windows_x86_64,
            else => @panic("the lazy vulkan-1 is x86_64 only (Hex uses Vulkan on x64 Windows only)"),
        },
        else => @panic("Vulkan here is for Linux and Windows"),
    };
    const name = if (abi == .windows_x86_64) "vulkan-1" else "vulkan";

    const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .pic = true });
    mod.addCSourceFile(.{ .file = b.addWriteFiles().add(b.fmt("{s}.c", .{name}), lazyLoader(b, abi, names.set.keys())), .flags = &.{"-w"} });
    const lib = b.addLibrary(.{ .name = name, .linkage = .static, .root_module = mod });
    lib.installHeadersDirectory(headers.path("include"), "", .{});
    b.installArtifact(lib);

    const prefix = b.addWriteFiles();
    _ = prefix.addCopyFile(lib.getEmittedBin(), b.fmt("lib/lib{s}.a", .{name}));
    if (abi == .windows_x86_64) _ = prefix.addCopyFile(lib.getEmittedBin(), "lib/vulkan-1.lib");
    _ = prefix.addCopyDirectory(headers.path("include"), "include", .{});
    b.addNamedLazyPath("prefix", prefix.getDirectory());
}

const Abi = enum { linux_x86_64, linux_aarch64, windows_x86_64 };

/// C (with assembly) for one thunk per export: the thunk jumps through its
/// slot once the slot is filled; until then it saves the argument registers,
/// has hex_vk_resolve fill the slot, restores them, and jumps to the
/// function. Arguments are in registers (and the stack, left untouched):
///
///   Windows x64:  rcx, rdx, r8, r9, xmm0-xmm3
///   SysV x86_64:  rdi, rsi, rdx, rcx, r8, r9, xmm0-xmm7
///   AArch64:      x0-x7, x8 (where a struct result goes), q0-q7
///
/// On Linux the thunks are hidden: the executable must not export a
/// vkGetInstanceProcAddr that the loader, once loaded, would bind its own
/// calls to.
fn lazyLoader(b: *std.Build, abi: Abi, names: []const []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    const a = b.allocator;
    const linux = abi != .windows_x86_64;
    const hidden = if (linux) "__attribute__((visibility(\"hidden\"))) " else "";
    out.print(a,
        \\#include <stdint.h>
        \\#include <stdio.h>
        \\#include <stdlib.h>
        \\{s}
        \\
        \\{s}void *hex_vk_slots[{d}];
        \\static const char *const hex_vk_names[{d}] = {{
        \\
    , .{
        if (linux) "#include <dlfcn.h>" else "#include <windows.h>",
        hidden,
        names.len,
        names.len,
    }) catch @panic("OOM");
    for (names) |name| out.print(a, "    \"{s}\",\n", .{name}) catch @panic("OOM");
    out.appendSlice(a, "};\n\n") catch @panic("OOM");

    if (linux) out.appendSlice(a,
        \\#define HEX_VK_LIBRARY "libvulkan.so.1"
        \\
        \\/* The system's loader, opened once (RTLD_LOCAL: wgpu opens its own). */
        \\static void *hex_vk_module(void) {
        \\    static void *module;
        \\    void *m = __atomic_load_n(&module, __ATOMIC_ACQUIRE);
        \\    if (!m) {
        \\        m = dlopen(HEX_VK_LIBRARY, RTLD_NOW | RTLD_LOCAL);
        \\        if (m) __atomic_store_n(&module, m, __ATOMIC_RELEASE);
        \\    }
        \\    return m;
        \\}
        \\
        \\static void *hex_vk_symbol(void *module, const char *name) {
        \\    return dlsym(module, name);
        \\}
        \\
        \\/* Before main, as Hex's src/windows/vulkan.rs does on Windows: keeps
        \\   ggml off Vulkan unless the loader is a Vulkan 1.2 one. */
        \\__attribute__((constructor)) static void hex_vk_check(void) {
        \\    if (getenv("GGML_DISABLE_VULKAN")) return;
        \\    void *module = hex_vk_module();
        \\    if (module && dlsym(module, "vkGetPhysicalDeviceFeatures2")) {
        \\        int32_t (*enumerate)(uint32_t *) = (int32_t (*)(uint32_t *))dlsym(module, "vkEnumerateInstanceVersion");
        \\        uint32_t version = 0;
        \\        if (enumerate && enumerate(&version) == 0) {
        \\            uint32_t major = version >> 22 & 0x7f, minor = version >> 12 & 0x3ff;
        \\            if (major > 1 || (major == 1 && minor >= 2)) return;
        \\        }
        \\    }
        \\    setenv("GGML_DISABLE_VULKAN", "1", 0);
        \\}
        \\
        \\
    ) catch @panic("OOM") else out.appendSlice(a,
        \\#define HEX_VK_LIBRARY "vulkan-1.dll"
        \\
        \\static void *hex_vk_module(void) {
        \\    static HMODULE module;
        \\    if (!module) module = LoadLibraryW(L"vulkan-1.dll");
        \\    return module;
        \\}
        \\
        \\static void *hex_vk_symbol(void *module, const char *name) {
        \\    return (void *)GetProcAddress((HMODULE)module, name);
        \\}
        \\
        \\
    ) catch @panic("OOM");

    out.print(a,
        \\{s}void *hex_vk_resolve(unsigned index) {{
        \\    void *module = hex_vk_module();
        \\    void *function = module ? hex_vk_symbol(module, hex_vk_names[index]) : NULL;
        \\    if (!function) {{
        \\        fprintf(stderr, HEX_VK_LIBRARY " %s %s\n", module ? "lacks" : "is missing; cannot call", hex_vk_names[index]);
        \\        abort();
        \\    }}
        \\    __atomic_store_n(&hex_vk_slots[index], function, __ATOMIC_RELEASE);
        \\    return function;
        \\}}
        \\
        \\__asm__(
        \\    "    .text\n"
        \\
    , .{hidden}) catch @panic("OOM");
    out.appendSlice(a, switch (abi) {
        .windows_x86_64 =>
        \\    "    .p2align 4\n"
        \\    "hex_vk_thunk:\n"
        \\    "    pushq %rcx\n"
        \\    "    pushq %rdx\n"
        \\    "    pushq %r8\n"
        \\    "    pushq %r9\n"
        \\    "    subq $104, %rsp\n"
        \\    "    movdqu %xmm0, 32(%rsp)\n"
        \\    "    movdqu %xmm1, 48(%rsp)\n"
        \\    "    movdqu %xmm2, 64(%rsp)\n"
        \\    "    movdqu %xmm3, 80(%rsp)\n"
        \\    "    movl %eax, %ecx\n"
        \\    "    call hex_vk_resolve\n"
        \\    "    movdqu 32(%rsp), %xmm0\n"
        \\    "    movdqu 48(%rsp), %xmm1\n"
        \\    "    movdqu 64(%rsp), %xmm2\n"
        \\    "    movdqu 80(%rsp), %xmm3\n"
        \\    "    addq $104, %rsp\n"
        \\    "    popq %r9\n"
        \\    "    popq %r8\n"
        \\    "    popq %rdx\n"
        \\    "    popq %rcx\n"
        \\    "    jmpq *%rax\n"
        \\
        ,
        // Entered with rsp 8 past a 16-byte boundary: six pushes and 136
        // bytes align it for the call.
        .linux_x86_64 =>
        \\    "    .p2align 4\n"
        \\    "    .type hex_vk_thunk, @function\n"
        \\    "hex_vk_thunk:\n"
        \\    "    pushq %rdi\n"
        \\    "    pushq %rsi\n"
        \\    "    pushq %rdx\n"
        \\    "    pushq %rcx\n"
        \\    "    pushq %r8\n"
        \\    "    pushq %r9\n"
        \\    "    subq $136, %rsp\n"
        \\    "    movdqu %xmm0, 0(%rsp)\n"
        \\    "    movdqu %xmm1, 16(%rsp)\n"
        \\    "    movdqu %xmm2, 32(%rsp)\n"
        \\    "    movdqu %xmm3, 48(%rsp)\n"
        \\    "    movdqu %xmm4, 64(%rsp)\n"
        \\    "    movdqu %xmm5, 80(%rsp)\n"
        \\    "    movdqu %xmm6, 96(%rsp)\n"
        \\    "    movdqu %xmm7, 112(%rsp)\n"
        \\    "    movl %eax, %edi\n"
        \\    "    call hex_vk_resolve\n"
        \\    "    movdqu 0(%rsp), %xmm0\n"
        \\    "    movdqu 16(%rsp), %xmm1\n"
        \\    "    movdqu 32(%rsp), %xmm2\n"
        \\    "    movdqu 48(%rsp), %xmm3\n"
        \\    "    movdqu 64(%rsp), %xmm4\n"
        \\    "    movdqu 80(%rsp), %xmm5\n"
        \\    "    movdqu 96(%rsp), %xmm6\n"
        \\    "    movdqu 112(%rsp), %xmm7\n"
        \\    "    addq $136, %rsp\n"
        \\    "    popq %r9\n"
        \\    "    popq %r8\n"
        \\    "    popq %rcx\n"
        \\    "    popq %rdx\n"
        \\    "    popq %rsi\n"
        \\    "    popq %rdi\n"
        \\    "    jmpq *%rax\n"
        \\
        ,
        // The index comes in w9, not in x16/x17, which a linker veneer for
        // the branch here may overwrite.
        .linux_aarch64 =>
        \\    "    .p2align 2\n"
        \\    "    .type hex_vk_thunk, %function\n"
        \\    "hex_vk_thunk:\n"
        \\    "    stp x29, x30, [sp, #-224]!\n"
        \\    "    mov x29, sp\n"
        \\    "    stp x0, x1, [sp, #16]\n"
        \\    "    stp x2, x3, [sp, #32]\n"
        \\    "    stp x4, x5, [sp, #48]\n"
        \\    "    stp x6, x7, [sp, #64]\n"
        \\    "    str x8, [sp, #80]\n"
        \\    "    stp q0, q1, [sp, #96]\n"
        \\    "    stp q2, q3, [sp, #128]\n"
        \\    "    stp q4, q5, [sp, #160]\n"
        \\    "    stp q6, q7, [sp, #192]\n"
        \\    "    mov w0, w9\n"
        \\    "    bl hex_vk_resolve\n"
        \\    "    mov x16, x0\n"
        \\    "    ldp q6, q7, [sp, #192]\n"
        \\    "    ldp q4, q5, [sp, #160]\n"
        \\    "    ldp q2, q3, [sp, #128]\n"
        \\    "    ldp q0, q1, [sp, #96]\n"
        \\    "    ldr x8, [sp, #80]\n"
        \\    "    ldp x6, x7, [sp, #64]\n"
        \\    "    ldp x4, x5, [sp, #48]\n"
        \\    "    ldp x2, x3, [sp, #32]\n"
        \\    "    ldp x0, x1, [sp, #16]\n"
        \\    "    ldp x29, x30, [sp], #224\n"
        \\    "    br x16\n"
        \\
        ,
    }) catch @panic("OOM");
    for (names, 0..) |name, i| {
        const stub = switch (abi) {
            .windows_x86_64 => out.print(a,
                \\    "    .globl {[n]s}\n"
                \\    "{[n]s}:\n"
                \\    "    movq hex_vk_slots+{[off]d}(%rip), %rax\n"
                \\    "    testq %rax, %rax\n"
                \\    "    jz 1f\n"
                \\    "    jmpq *%rax\n"
                \\    "1:  movl ${[i]d}, %eax\n"
                \\    "    jmp hex_vk_thunk\n"
                \\
            , .{ .n = name, .off = i * 8, .i = i }),
            .linux_x86_64 => out.print(a,
                \\    "    .globl {[n]s}\n"
                \\    "    .hidden {[n]s}\n"
                \\    "    .type {[n]s}, @function\n"
                \\    "{[n]s}:\n"
                \\    "    movq hex_vk_slots+{[off]d}(%rip), %rax\n"
                \\    "    testq %rax, %rax\n"
                \\    "    jz 1f\n"
                \\    "    jmpq *%rax\n"
                \\    "1:  movl ${[i]d}, %eax\n"
                \\    "    jmp hex_vk_thunk\n"
                \\
            , .{ .n = name, .off = i * 8, .i = i }),
            .linux_aarch64 => out.print(a,
                \\    "    .globl {[n]s}\n"
                \\    "    .hidden {[n]s}\n"
                \\    "    .type {[n]s}, %function\n"
                \\    "{[n]s}:\n"
                \\    "    adrp x9, hex_vk_slots+{[off]d}\n"
                \\    "    ldr x10, [x9, :lo12:hex_vk_slots+{[off]d}]\n"
                \\    "    cbz x10, 1f\n"
                \\    "    br x10\n"
                \\    "1:  mov w9, #{[i]d}\n"
                \\    "    b hex_vk_thunk\n"
                \\
            , .{ .n = name, .off = i * 8, .i = i }),
        };
        stub catch @panic("OOM");
    }
    out.appendSlice(a, ");\n") catch @panic("OOM");
    return out.items;
}
