import pathlib, sys

def uleb(b, i):
    n = 0
    sh = 0
    while True:
        by = b[i]
        i += 1
        n |= (by & 0x7f) << sh
        sh += 7
        if not (by & 0x80):
            break
    return n, i

b = pathlib.Path('E:/cva6/g6lc_bios/browser-ui/out/bios-ui-libwasm.wasm').read_bytes()
assert b[:4] == b'\0asm'
i = 8
fn_target = int(sys.argv[1]) if len(sys.argv) > 1 else 64
fn_i = 0
while i < len(b):
    sec_id = b[i]; i += 1
    size, i = uleb(b, i)
    end = i + size
    payload = b[i:end]
    if sec_id == 10:
        j = 0
        n, j = uleb(payload, j)
        for _ in range(n):
            fsize, j = uleb(payload, j)
            body = payload[j:j+fsize]
            j += fsize
            if fn_i == fn_target:
                print('func', fn_i, 'body len', fsize, 'bytes', body.hex())
                sys.exit(0)
            fn_i += 1
    i = end
