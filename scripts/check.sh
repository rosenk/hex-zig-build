#!/bin/sh
# Checks what README.md promises about the executable `zig build` makes:
#
#   scripts/check.sh zig-out/bin/hex [2.27]    Linux: needs no glibc symbol
#       newer than the version given, and no shared library but glibc's own,
#       libasound.so.2 and libxkbcommon.so.0
#   scripts/check.sh zig-out/bin/hex.exe       Windows: imports neither
#       vulkan-1.dll (deps/vulkan loads it on first use) nor a MinGW runtime DLL
#
# Needs readelf and objdump (binutils).
set -eu

exe=$1
glibc_max=${2:-2.27}
failed=0

case $exe in
*.exe)
    dlls=$(objdump -p "$exe" | sed -n 's/^[[:space:]]*DLL Name: //p' | tr 'A-Z' 'a-z' | sort -u)
    [ -n "$dlls" ] || { echo "$exe: no imports found; is it a PE executable?" >&2; exit 1; }
    echo "imports:" $dlls
    for dll in $dlls; do
        case $dll in
        vulkan-1.dll | libstdc++-*.dll | libc++*.dll | libgcc_s*.dll | libwinpthread-*.dll | libunwind*.dll)
            echo "$exe: imports $dll" >&2
            failed=1
            ;;
        esac
    done
    ;;
*)
    needed=$(readelf -d "$exe" | sed -n 's/.*(NEEDED).*\[\(.*\)\]$/\1/p' | sort -u)
    [ -n "$needed" ] || { echo "$exe: no DT_NEEDED entries; is it a dynamic ELF executable?" >&2; exit 1; }
    echo "needs:" $needed
    for lib in $needed; do
        case $lib in
        libc.so.6 | libm.so.6 | libdl.so.2 | libpthread.so.0 | librt.so.1 | libutil.so.1 | ld-linux-*.so.*) ;;
        libasound.so.2 | libxkbcommon.so.0) ;;
        *)
            echo "$exe: needs $lib" >&2
            failed=1
            ;;
        esac
    done

    glibc=$(readelf -V "$exe" | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/^GLIBC_//' | sort -u -V | tail -n 1)
    [ -n "$glibc" ] || { echo "$exe: no GLIBC symbol versions found" >&2; exit 1; }
    echo "newest glibc symbol version: $glibc (limit $glibc_max)"
    if [ "$(printf '%s\n%s\n' "$glibc" "$glibc_max" | sort -V | tail -n 1)" != "$glibc_max" ]; then
        echo "$exe: needs GLIBC_$glibc, newer than $glibc_max" >&2
        failed=1
    fi
    ;;
esac

exit $failed
