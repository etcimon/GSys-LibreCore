import pathlib
b = pathlib.Path('E:/cva6/g6lc_bios/browser-ui/out/bios-ui-libwasm.wasm').read_bytes()
assert b[:4] == b'\0asm'
i = 8
func_i = 0
while i < len(b):
    sec_id = b[i]
    i += 1
    n = 0
    sh = 0
    while True:
        by = b[i]
        i += 1
        n |= (by & 0x7f) << sh
        sh += 7
        if not (by & 0x80):
            break
    end = i + n
    payload = b[i:end]
    if sec_id == 10:
        print('code section length', n)
        j = 0
        fc = 0
        while j < len(payload):
            fn = 0
            sh2 = 0
            while True:
                by = payload[j]
                j += 1
                fn |= (by & 0x7f) << sh2
                sh2 += 7
                if not (by & 0x80):
                    break
            body = payload[j:j + fn]
            j += fn
            first = body.find(b'\x0a')
            if first != -1:
                print('func', fc, '0x0a at', first, 'body_len', len(body), 'body[:20]', body[:20].hex(), 'body[-5:]', body[-5:].hex())
                break
            fc += 1
        break
    i = end
