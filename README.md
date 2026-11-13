# hex-zig-build

Builds [Hex](https://github.com/anomalyco/hex) with `zig build` and `cargo
zigbuild` for Linux with glibc 2.27 (Debian 10, Ubuntu 18.04 and newer), and
cross-compiles it for Windows x64 (MinGW). Hex is a dependency like any
other: `deps/hex` pins its sources by commit and builds the program as it
is. One patch, `deps/hex/windows-gnu.patch`, touches only its build script
(MSVC-only link flags, and the icon from a cross build).

```sh
mise install
zig build                                    # zig-out/bin/hex, x86_64, glibc 2.27
zig build -Dtarget=aarch64-linux-gnu.2.27    # ARM64
zig build -Dtarget=x86_64-windows-gnu        # zig-out/bin/hex.exe, Windows x64
zig build -Doptimize=ReleaseFast             # Debug, ReleaseSafe (default), ReleaseFast, ReleaseSmall
zig build -j4                                # at most 4 steps at once, and cargo -j4
zig build -- --features onnx-benchmark       # extra cargo arguments
```

`-jN` is not `make -jN`: Zig limits how many steps run at once, but each
C/C++ compile step still uses every core, since Zig neither passes `-j` to
its compiler nor has a jobserver yet
([ziglang/zig#20274](https://github.com/ziglang/zig/issues/20274)). cargo's
step reads `-jN` from `zig build`'s command line and runs cargo with
`CARGO_BUILD_JOBS=N`, which rustc, build scripts and the cc crate share.

Tools come from `mise.toml`: Zig 0.17, the newest stable Rust,
cargo-zigbuild, Python (SPIRV-Tools' table generators) and Perl (OpenSSL's
Configure and generators) as self-contained prebuilt binaries. No CMake, no
make, no Docker, and no system tool or `-dev` package: every native library
is built by Zig from sources a `build.zig.zon` pins.

## Optimization

`-Doptimize` sets one mode for everything: each package passes it to its
dependencies, so the C and C++ libraries, glslc, and the stand-ins build with
it, and `deps/hex` maps it onto cargo's profiles:

| `-Doptimize` | C/C++ (Zig) | Hex (cargo) |
| --- | --- | --- |
| `ReleaseSafe` (default) | optimized, undefined-behaviour checks trap (not in transcribe/ggml) | `--release` with overflow checks |
| `ReleaseFast` | optimized, no checks (what Hex's CMake release does) | `--release` |
| `ReleaseSmall` | optimized for size | `--release`, `opt-level = "s"` |
| `Debug` | unoptimized, checks on | dev profile |

ReleaseSafe makes Zig compile the C and C++ code with UBSan in trap mode, so
undefined behaviour in OpenSSL or the shader tools stops the program instead of
passing silently (a SIGILL, `ud1`/`ud2`; build with Debug to get UBSan's
message). transcribe.cpp and ggml are the exception: they build without UBSan
in every mode but Debug, and with -O3 in ReleaseSafe and ReleaseFast, as in
Hex's CMake release, since UBSan's overflow and bounds traps sit in the CPU
kernels' inner loops (tinyBLAS, ops) and halved the CPU backend's speed. In Debug ggml
leaves out the function-type check, which its typed kernels, called through
generic function pointers, trip on every call. ReleaseFast builds what Hex's
own release builds.

## Dependencies

Each package under `deps/` names what it needs in its own `build.zig.zon` and
hands its users a prefix (a named lazy path) or an artifact.

```
hex-zig-build
└── deps/hex              Hex v3.4.0 (8766d096) + build script patch, cargo zigbuild
    ├── deps/helpers      applies the patch
    ├── deps/transcribe   transcribe.cpp + ggml (CPU, Vulkan) → TRANSCRIBE_DIR
    │   ├── deps/vulkan          Vulkan headers + a static library that loads
    │   │                        libvulkan.so.1 / vulkan-1.dll on first use
    │   │   └── deps/helpers
    │   ├── deps/spirv-headers
    │   └── deps/shaderc         glslc, built for the build machine
    │       ├── deps/glslang
    │       │   └── deps/spirv-tools
    │       ├── deps/spirv-tools
    │       │   └── deps/spirv-headers
    │       └── deps/spirv-headers
    ├── deps/openssl      OpenSSL 3.5 LTS, static → OPENSSL_DIR, Linux only
    ├── deps/alsa         libasound.so.2 stand-in (cpal), Linux only
    │   └── deps/helpers
    └── deps/xkbcommon    libxkbcommon.so.0 stand-in (Rune), Linux only
        └── deps/helpers
```

- **deps/hex** runs `cargo zigbuild` in a patched copy of Hex's sources with
  the prefixes of its dependencies, and checks that `deps/transcribe` builds the
  transcribe.cpp revision Hex's `Cargo.toml` patches in. It also makes an
  empty `libopenblas.so` for the `-lopenblas` Hex's `build.rs` always passes
  on Linux; nothing uses it, so the linker drops it.
- **deps/hex/windows-gnu.patch**: Hex's `build.rs` delay-loads
  `vulkan-1.dll` with `/DELAYLOAD` and `delayimp`, which only an MSVC link
  takes; the patch passes them to MSVC links only. It also links the `.res`
  file `HEX_WINDOWS_RES` names when `build.rs` runs on another OS than
  Windows, where its own resource step is compiled out.
- `deps/helpers` applies the patch while the build is configured
  (no patch(1) or git): every hunk must match exactly, near its line, or the
  build stops and names the hunk.
- **deps/transcribe** builds transcribe.cpp and ggml with the options Hex's
  release passes to CMake (static, `GGML_NATIVE=OFF`, no BLAS, Vulkan shaders
  for f32, f16, q8_0, q5_0 only, no MUL_MAT_ID), and writes the
  `transcribe-link.json` manifest transcribe-cpp-sys reads.
- **deps/openssl** runs upstream OpenSSL's `Configure` and the generators its
  Makefile would (`openssl.pl`, with mise's perl), then Zig compiles the
  sources Configure chose, perlasm assembly included, into static `libssl.a`
  and `libcrypto.a` for openssl-sys (Hex's native-tls on Linux).
  `OPENSSLDIR` is `/etc/ssl`, so the system's CA certificates are trusted.
  Static because Debian 10 and 11 and Ubuntu 18.04 and 20.04 ship
  `libssl.so.1.1`, and Debian 12 and Ubuntu 22.04 and newer only
  `libssl.so.3`. Configure's plan is kept under
  `deps/openssl/.zig-cache/openssl-plan/`, and every step's inputs are only
  the release, `openssl.pl`, the target, and the options (no copy of the
  environment), so OpenSSL compiles once per target and mode.
- **deps/vulkan** builds a static library with the Vulkan loader's exports
  (`loader/vulkan-1.def`) whose functions open the system's loader on their
  first call (`libvulkan.so.1` through dlopen, `vulkan-1.dll` through
  LoadLibrary): one thunk per export, for x86_64 and aarch64. The executable
  needs no Vulkan to start. On Linux it also checks the loader before `main`,
  as Hex does on Windows (`src/windows/vulkan.rs`): without Vulkan 1.2 it
  sets `GGML_DISABLE_VULKAN`, and speech runs on the CPU.
- **deps/alsa**, **deps/xkbcommon** are link-time stand-ins: shared
  libraries with the real soname whose functions are empty, generated from
  the upstream headers (`deps/helpers`). The executable records only the
  soname, and the system's own library answers at run time.
- **deps/shaderc**, **deps/glslang**, **deps/spirv-tools**,
  **deps/spirv-headers** are at the revisions shaderc v2026.1's `DEPS` file
  pins.

The executable needs `GLIBC_2.27` at most, links Zig's libc++ and OpenSSL
statically (no libstdc++, libgcc_s, or libssl), and needs only
`libxkbcommon.so.0`, `libasound.so.2`, and glibc from the system to start;
`libvulkan.so.1` is opened when there is one. Hex's own Linux release, built
on Debian 12, needs glibc 2.36 and `libssl.so.3`. The C and C++ code builds
for the architecture's baseline (plus the x86_64 features ggml's release
needs), not the build machine's CPU.

| | glibc | Vulkan loader | Mesa (Vulkan) | Speech |
| --- | --- | --- | --- | --- |
| Debian 10 | 2.28 | 1.1 | 18.3 (1.1) | CPU; GPU with buster-backports' `libvulkan1` and Mesa 20.3 |
| Ubuntu 18.04 | 2.27 | 1.1 | 20.0 (1.2) | CPU: ggml checks the loader's version |
| Debian 11, Ubuntu 20.04 and newer | 2.31+ | 1.2+ | 20.3+ (1.2+) | GPU |

ggml's Vulkan backend needs a Vulkan 1.2 loader and driver; without them it
does not register, and speech runs on the CPU at the same CPU speed as on a
newer system. The window draws through wgpu with Vulkan only (Rune enables no
OpenGL backend on Linux), so it needs the system's `libvulkan1` and a Vulkan
driver for the GPU (Mesa's `mesa-vulkan-drivers`, or NVIDIA's own); a Vulkan
1.1 driver is enough for it. Older targets build too
(`-Dtarget=x86_64-linux-gnu.2.17`), but Debian 9 and Ubuntu 16.04 have only
Vulkan 1.0 and the first Mesa Vulkan drivers, which nothing here has been
tried on.

## Windows

`-Dtarget=x86_64-windows-gnu` builds `hex.exe` for Windows 10 and newer with
Rust's `x86_64-pc-windows-gnu` target, linked by Zig (MinGW-w64, libc++
static), so no MSVC or Windows SDK is needed. Differences from Hex's own MSVC
release:

- Vulkan: Zig's linker has no `/DELAYLOAD`, so `deps/vulkan`'s static
  `vulkan-1` loads `vulkan-1.dll` on first use instead. The executable
  imports no `vulkan-1.dll` and starts without one, as the delay-loaded
  original does; Hex checks for Vulkan before ggml uses it.
- Icon and version resource: Hex's `build.rs` embeds them only when it runs
  on Windows, so `deps/hex` writes the same resource script (icon
  `resources/windows/hex.ico`, the version from Hex's `Cargo.toml`), compiles
  it with `zig rc`, and the patched `build.rs` links the `.res`.
- HTTPS is native-tls through SChannel, as in Hex's release (no OpenSSL).

## Updating Hex

Point `deps/hex/build.zig.zon` at the new commit (in `deps/hex`:
`zig fetch --save=hex https://github.com/anomalyco/hex/archive/<sha>.tar.gz`).
If its `Cargo.toml` moves the transcribe.cpp rev, the build stops and says
so: move `deps/transcribe`'s `transcribe_cpp` dependency and
`transcribe_commit` to the same rev, and check its source list and options
against transcribe.cpp's CMake files.

If `windows-gnu.patch` no longer applies, the build names the hunk. Remake
it on the new sources: make the same change to `build.rs` and save
`git diff`.
