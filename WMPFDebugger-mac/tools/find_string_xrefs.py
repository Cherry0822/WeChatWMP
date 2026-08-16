#!/usr/bin/env python3
"""Static ARM64 string xref finder for stripped Mach-O (WeChatAppEx Framework).

Usage:
    python3 tools/find_string_xrefs.py <macho-arm64-slice> <string> [<string> ...]

Scans __TEXT,__text for ADRP+ADD instructions that reference the given string
literal, then walks backward to estimate the containing function entry.
Outputs module-relative offsets suitable for frida/config/addresses.*.json.
WeChatAppEx Framework's __TEXT vmaddr is 0, so module offset == static VA.
"""

import struct
import sys

from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM


MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19


def read_u32(buf, off):
    return struct.unpack_from("<I", buf, off)[0]


def read_u64(buf, off):
    return struct.unpack_from("<Q", buf, off)[0]


def parse_macho(path):
    with open(path, "rb") as f:
        buf = f.read()
    magic = read_u32(buf, 0)
    if magic != MH_MAGIC_64:
        raise SystemExit(f"not a little-endian arm64 Mach-O (magic=0x{magic:x})")

    ncmds = read_u32(buf, 16)
    off = 32
    segments = []  # (vmaddr, vmsize, fileoff, filesize, name)
    sections = []  # (vmaddr, fileoff, size, segname, sectname, flags)
    for _ in range(ncmds):
        cmd = read_u32(buf, off)
        cmdsize = read_u32(buf, off + 4)
        if cmd == LC_SEGMENT_64:
            segname = buf[off + 8 : off + 24].split(b"\0")[0].decode()
            vmaddr = read_u64(buf, off + 24)
            vmsize = read_u64(buf, off + 32)
            fileoff = read_u64(buf, off + 40)
            filesize = read_u64(buf, off + 48)
            nsects = read_u32(buf, off + 64)
            segments.append((vmaddr, vmsize, fileoff, filesize, segname))
            so = off + 72
            for _ in range(nsects):
                sname = buf[so : so + 16].split(b"\0")[0].decode()
                sseg = buf[so + 16 : so + 32].split(b"\0")[0].decode()
                s_addr = read_u64(buf, so + 32)
                s_size = read_u64(buf, so + 40)
                s_off = read_u32(buf, so + 48)
                sections.append((s_addr, s_off, s_size, sseg, sname))
                so += 80
        off += cmdsize
    return buf, segments, sections


def vmaddr_for_fileoff(segments, fileoff):
    for vmaddr, vmsize, foff, fsize, _ in segments:
        if foff <= fileoff < foff + fsize:
            return vmaddr + (fileoff - foff)
    raise SystemExit(f"string file offset 0x{fileoff:x} not inside any segment")


def find_string_va(buf, segments, text):
    data = text.encode()
    pos = buf.find(data)
    if pos == -1:
        return None
    return vmaddr_for_fileoff(segments, pos)


def decode_adrp(word, pc):
    if (word & 0x9F000000) != 0x90000000:
        return None
    immlo = (word >> 29) & 0x3
    immhi = (word >> 5) & 0x7FFFF
    imm = (immhi << 2) | immlo
    if imm & 0x100000:
        imm -= 0x200000
    return (pc & ~0xFFF) + (imm << 12)


def decode_add_imm(word):
    # ADD immediate: sf=1 op=0 S=0 -> 0x91000000 mask, shift=0
    if (word & 0xFFC00000) != 0x91000000:
        return None
    if (word >> 22) & 0x3:
        return None
    return (word >> 10) & 0xFFF


def find_function_start(buf, text_fileoff, text_vmaddr, xref_vmaddr, window=0x300):
    """Scan backward from xref for an AArch64 prologue; fallback to nearest ret."""
    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    md.detail = False
    start = max(text_vmaddr, xref_vmaddr - window)
    start_off = text_fileoff + (start - text_vmaddr)
    end_off = text_fileoff + (xref_vmaddr - text_vmaddr)
    code = buf[start_off:end_off]
    insns = list(md.disasm(code, start))
    entry = None
    last_ret = None
    for insn in insns:
        m = insn.mnemonic
        if m == "ret":
            last_ret = insn.address
        if m == "stp" and insn.op_str.startswith("x29, x30"):
            entry = insn.address
        elif m == "sub" and insn.op_str.startswith("sp, sp, #") and entry is None:
            entry = insn.address
    if entry is None and last_ret is not None:
        entry = last_ret + 4
    return entry


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    path = sys.argv[1]
    targets = sys.argv[2:]

    print(f"[*] parsing {path}")
    buf, segments, sections = parse_macho(path)

    text = next((s for s in sections if s[3] == "__TEXT" and s[4] == "__text"), None)
    if not text:
        raise SystemExit("__TEXT,__text section not found")
    text_vmaddr, text_fileoff, text_size, _, _ = text
    print(
        f"[*] __text vmaddr=0x{text_vmaddr:x} fileoff=0x{text_fileoff:x} "
        f"size=0x{text_size:x}"
    )

    for target in targets:
        va = find_string_va(buf, segments, target)
        if va is None:
            print(f"[!] string not found: {target!r}")
            continue
        print(f"\n=== string: {target!r}")
        print(f"    va=0x{va:x}  module_offset=0x{va:x}")
        page = va & ~0xFFF

        xrefs = []
        word_count = text_size // 4
        for i in range(word_count):
            w = read_u32(buf, text_fileoff + i * 4)
            if (w & 0x9F000000) != 0x90000000:
                continue
            pc = text_vmaddr + i * 4
            tpage = decode_adrp(w, pc)
            if tpage != page:
                continue
            for j in range(i + 1, min(i + 9, word_count)):
                w2 = read_u32(buf, text_fileoff + j * 4)
                add_imm = decode_add_imm(w2)
                if add_imm is None:
                    continue
                rd = w2 & 0x1F
                rn = (w2 >> 5) & 0x1F
                if rd == rn and page + add_imm == va:
                    xref_vmaddr = text_vmaddr + j * 4
                    entry = find_function_start(
                        buf, text_fileoff, text_vmaddr, xref_vmaddr
                    )
                    xrefs.append((xref_vmaddr, entry))
                    break

        if not xrefs:
            print("    (no ADRP+ADD xrefs found)")
            continue
        seen = set()
        for xref_vmaddr, entry in xrefs:
            key = entry if entry else xref_vmaddr
            if key in seen:
                continue
            seen.add(key)
            loc = entry if entry else xref_vmaddr
            print(f"    xref=0x{xref_vmaddr:x} -> func=0x{loc:x} (module offsets)")


if __name__ == "__main__":
    main()
