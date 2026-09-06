/* generated from g6b-asm IR — do not hand-edit */
.option norvc

/* purpose=hmac home=sha256 */
	/* HMAC-SHA256 ipad/opad: xor key with 0x36 / 0x5c (Botan mac/hmac) */
.globl hmac_xor_pad
hmac_xor_pad:
	xor	a0, a0, a1
	ret

/* purpose=rsa home=a0=n,a1=e,a2=sig */
	/* RSA modexp limb: mul a0, a1, a2  (PKCS#1 v1.5 SHA-256 verify) */
.globl rsa_limb_mul
rsa_limb_mul:
	mul	a0, a1, a2
	ret

/* purpose=ecdsa home=p256 */
	/* ECDSA P-256 point add: add t0, a0, a1 (field limb) */
.globl ecdsa_p256_add
ecdsa_p256_add:
	add	t0, a0, a1
	ret

/* purpose=cert home=der */
	/* X.509 DER length walk: lbu t1, 0(a0) */
.globl cert_der_len
cert_der_len:
	lbu	t1, 0(a0)
	ret
