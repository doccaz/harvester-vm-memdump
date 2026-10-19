#!/usr/bin/env python3
"""Convert a QEMU memory-only ELF core (from vm-memdump.sh) into a Windows MEMORY.DMP for WinDbg.

Steps: write the ELF LOAD segments to a sparse raw physical-memory image, let MemProcFS
(`pip install memprocfs`) build a crash dump from it (it decodes the KdDebuggerDataBlock and fills
the DUMP_HEADER64), and copy that out. Windows x64 guests only. Needs ~1x guest RAM of temp space
plus the output size (the .dmp spans the whole physical address range, so up to 2x RAM for >3 GiB guests).

Usage: elf2windmp.py <in.memory.dump[.gz]> <out.dmp>
"""
import gzip, os, struct, sys, tempfile

CHUNK = 1 << 24


def elf_to_raw(src, dst):
    f = gzip.open(src, 'rb') if src.endswith('.gz') else open(src, 'rb')
    if src.endswith('.gz'):  # gzip streams can't seek back; spool the ELF to a temp file first
        tmp = tempfile.NamedTemporaryFile(dir=os.path.dirname(os.path.abspath(dst)), suffix='.elf', delete=False)
        while chunk := f.read(CHUNK):
            tmp.write(chunk)
        tmp.close(); f.close()
        try:
            return elf_to_raw(tmp.name, dst)
        finally:
            os.unlink(tmp.name)
    head = f.read(64)
    if head[:4] != b'\x7fELF' or head[4] != 2:
        sys.exit('not a 64-bit ELF core')
    phoff, = struct.unpack_from('<Q', head, 32)
    phentsize, phnum = struct.unpack_from('<HH', head, 54)
    segs = []
    for i in range(phnum):
        f.seek(phoff + i * phentsize)
        t, _, off, _, pa, fsz, _, _ = struct.unpack('<IIQQQQQQ', f.read(56))
        if t == 1:  # PT_LOAD
            segs.append((off, pa, fsz))
    with open(dst, 'wb') as out:
        for off, pa, fsz in segs:
            f.seek(off); out.seek(pa); left = fsz
            while left:
                b = f.read(min(left, CHUNK)); out.write(b); left -= len(b)
        out.truncate(max(pa + fsz for _, pa, fsz in segs))
    return segs


def raw_to_dmp(raw, dst):
    try:
        import memprocfs
    except ImportError:
        sys.exit('missing module: pip install memprocfs')
    vmm = memprocfs.Vmm(['-device', raw])
    size = vmm.vfs.list('/')['memory.dmp']['size']
    zero = bytes(CHUNK)
    with open(dst, 'wb') as out:
        off = 0
        while off < size:
            b = vmm.vfs.read('/memory.dmp', min(CHUNK, size - off), off)
            if not b:
                sys.exit(f'short read from MemProcFS at {off:#x}')
            if b == zero[:len(b)]:
                out.seek(len(b), 1)  # keep zero regions sparse
            else:
                out.write(b)
            off += len(b)
        out.truncate(size)
    with open(dst, 'rb') as chk:
        if chk.read(8) != b'PAGEDU64':
            sys.exit('output has no PAGEDU64 header')


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, dst = sys.argv[1:]
    raw = dst + '.raw.tmp'
    try:
        print('==> ELF -> raw physical image', file=sys.stderr)
        elf_to_raw(src, raw)
        print('==> MemProcFS -> MEMORY.DMP', file=sys.stderr)
        raw_to_dmp(raw, dst)
    finally:
        if os.path.exists(raw):
            os.unlink(raw)
    print(dst)


if __name__ == '__main__':
    main()
