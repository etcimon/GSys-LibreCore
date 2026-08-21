# Show bytes at VA 0x80000008 in the compiled mini ELF.
import struct
p = "/tmp/cva6-mini-p3split/mini_fdt_a0_is_fdt.elf"
d = open(p, "rb").read()
# ELF64 program headers: e_phoff@32, e_phentsize@54, e_phnum@56
e_phoff = struct.unpack_from("<Q", d, 32)[0]
e_phentsize = struct.unpack_from("<H", d, 54)[0]
e_phnum = struct.unpack_from("<H", d, 56)[0]
print("phoff", hex(e_phoff), "phnum", e_phnum)
for i in range(e_phnum):
    o = e_phoff + i * e_phentsize
    p_type, p_flags = struct.unpack_from("<II", d, o)
    p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align = struct.unpack_from(
        "<QQQQQQ", d, o + 8
    )
    print(
        f"ph{i} type={p_type} off={hex(p_offset)} va={hex(p_vaddr)} filesz={hex(p_filesz)}"
    )
    va = 0x80000008
    if p_type == 1 and p_vaddr <= va < p_vaddr + p_filesz:
        fo = p_offset + (va - p_vaddr)
        chunk = d[fo : fo + 16]
        print("va 80000008 file", hex(fo), chunk.hex())
        print("be32", hex(int.from_bytes(chunk[0:4], "big")))
        print("le32", hex(int.from_bytes(chunk[0:4], "little")))
