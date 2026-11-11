#!/usr/bin/env python3
"""Clear the executable-stack request (PT_GNU_STACK X flag) of ELF shared objects.

AMD's Ryzen AI / ONNX Runtime binaries are built on Ubuntu with an executable stack
request. Kernels >= 6.6 refuse to honour that request for dlopen()ed objects, which shows
up as:

    ImportError: .../onnxruntime_pybind11_state.so: cannot enable executable stack as
    shared object requires: Invalid argument

`patchelf` in nixpkgs has no option for this, so rewrite p_flags in place. Nothing is
resized: the file keeps its size and layout, only the X bit of PT_GNU_STACK is cleared.
"""

import struct
import sys

PT_GNU_STACK = 0x6474E551


def patch(path: str) -> bool:
    with open(path, "r+b") as handle:
        head = handle.read(64)
        if len(head) < 64 or head[:4] != b"\x7fELF":
            return False
        is64 = head[4] == 2
        endian = "<" if head[5] == 1 else ">"
        if is64:
            e_phoff = struct.unpack_from(endian + "Q", head, 0x20)[0]
            e_phentsize = struct.unpack_from(endian + "H", head, 0x36)[0]
            e_phnum = struct.unpack_from(endian + "H", head, 0x38)[0]
            flags_offset = 4
        else:
            e_phoff = struct.unpack_from(endian + "I", head, 0x1C)[0]
            e_phentsize = struct.unpack_from(endian + "H", head, 0x2A)[0]
            e_phnum = struct.unpack_from(endian + "H", head, 0x2C)[0]
            flags_offset = 24
        if not e_phentsize or not e_phnum:
            return False

        changed = False
        for index in range(e_phnum):
            offset = e_phoff + index * e_phentsize
            handle.seek(offset)
            phdr = handle.read(e_phentsize)
            if len(phdr) < e_phentsize:
                break
            if struct.unpack_from(endian + "I", phdr, 0)[0] != PT_GNU_STACK:
                continue
            handle.seek(offset + flags_offset)
            flags = struct.unpack(endian + "I", handle.read(4))[0]
            if flags & 1:
                handle.seek(offset + flags_offset)
                handle.write(struct.pack(endian + "I", flags & ~1))
                changed = True
        return changed


def main() -> int:
    patched = 0
    total = 0
    for path in sys.argv[1:]:
        total += 1
        try:
            if patch(path):
                patched += 1
        except OSError as exc:
            print(f"strip-execstack: skipping {path}: {exc}", file=sys.stderr)
    print(f"strip-execstack: cleared executable stack on {patched}/{total} objects")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
