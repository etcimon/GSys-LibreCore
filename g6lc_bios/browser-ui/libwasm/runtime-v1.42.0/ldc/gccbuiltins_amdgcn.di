module ldc.gccbuiltins_amdgcn; 

import core.simd;

nothrow @nogc:

pragma(LDC_intrinsic, "llvm.amdgcn.alignbyte")
    int __builtin_amdgcn_alignbyte(int, int, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.ashr.pk.i8.i32")
    short __builtin_amdgcn_ashr_pk_i8_i32(int, int, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.ashr.pk.u8.i32")
    short __builtin_amdgcn_ashr_pk_u8_i32(int, int, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.buffer.wbinvl1")
    void __builtin_amdgcn_buffer_wbinvl1() pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.buffer.wbinvl1.sc")
    void __builtin_amdgcn_buffer_wbinvl1_sc() pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.buffer.wbinvl1.vol")
    void __builtin_amdgcn_buffer_wbinvl1_vol() pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cubeid")
    float __builtin_amdgcn_cubeid(float, float, float) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cubema")
    float __builtin_amdgcn_cubema(float, float, float) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cubesc")
    float __builtin_amdgcn_cubesc(float, float, float) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cubetc")
    float __builtin_amdgcn_cubetc(float, float, float) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cvt.f32.bf8")
    float __builtin_amdgcn_cvt_f32_bf8(int, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cvt.f32.fp8")
    float __builtin_amdgcn_cvt_f32_fp8(int, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cvt.f32.fp8.e5m3")
    float __builtin_amdgcn_cvt_f32_fp8_e5m3(int, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cvt.off.f32.i4")
    float __builtin_amdgcn_cvt_off_f32_i4(int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cvt.pk.bf8.f32")
    int __builtin_amdgcn_cvt_pk_bf8_f32(float, float, int, bool) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cvt.pk.f32.bf8")
    float2 __builtin_amdgcn_cvt_pk_f32_bf8(int, bool) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cvt.pk.f32.fp8")
    float2 __builtin_amdgcn_cvt_pk_f32_fp8(int, bool) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cvt.pk.fp8.f32")
    int __builtin_amdgcn_cvt_pk_fp8_f32(float, float, int, bool) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cvt.pk.i16")
    short2 __builtin_amdgcn_cvt_pk_i16(int, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cvt.pk.u16")
    short2 __builtin_amdgcn_cvt_pk_u16(int, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cvt.pk.u8.f32")
    int __builtin_amdgcn_cvt_pk_u8_f32(float, int, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cvt.pknorm.i16")
    short2 __builtin_amdgcn_cvt_pknorm_i16(float, float) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cvt.pknorm.u16")
    short2 __builtin_amdgcn_cvt_pknorm_u16(float, float) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cvt.scalef32.2xpk16.bf6.f32")
    int6 __builtin_amdgcn_cvt_scalef32_2xpk16_bf6_f32(float16, float16, float) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cvt.scalef32.2xpk16.fp6.f32")
    int6 __builtin_amdgcn_cvt_scalef32_2xpk16_fp6_f32(float16, float16, float) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cvt.scalef32.f32.bf8")
    float __builtin_amdgcn_cvt_scalef32_f32_bf8(int, float, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cvt.scalef32.f32.fp8")
    float __builtin_amdgcn_cvt_scalef32_f32_fp8(int, float, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cvt.scalef32.pk32.f32.bf6")
    float32 __builtin_amdgcn_cvt_scalef32_pk32_f32_bf6(int6, float) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cvt.scalef32.pk32.f32.fp6")
    float32 __builtin_amdgcn_cvt_scalef32_pk32_f32_fp6(int6, float) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cvt.scalef32.pk.bf8.f32")
    short2 __builtin_amdgcn_cvt_scalef32_pk_bf8_f32(short2, float, float, float, bool) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cvt.scalef32.pk.f32.bf8")
    float2 __builtin_amdgcn_cvt_scalef32_pk_f32_bf8(int, float, bool) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cvt.scalef32.pk.f32.fp4")
    float2 __builtin_amdgcn_cvt_scalef32_pk_f32_fp4(int, float, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cvt.scalef32.pk.f32.fp8")
    float2 __builtin_amdgcn_cvt_scalef32_pk_f32_fp8(int, float, bool) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cvt.scalef32.pk.fp4.f32")
    int __builtin_amdgcn_cvt_scalef32_pk_fp4_f32(int, float, float, float, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cvt.scalef32.pk.fp8.f32")
    short2 __builtin_amdgcn_cvt_scalef32_pk_fp8_f32(short2, float, float, float, bool) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cvt.scalef32.sr.bf8.f32")
    int __builtin_amdgcn_cvt_scalef32_sr_bf8_f32(int, float, int, float, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cvt.scalef32.sr.fp8.f32")
    int __builtin_amdgcn_cvt_scalef32_sr_fp8_f32(int, float, int, float, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cvt.scalef32.sr.pk32.bf6.f32")
    int6 __builtin_amdgcn_cvt_scalef32_sr_pk32_bf6_f32(float32, int, float) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cvt.scalef32.sr.pk32.fp6.f32")
    int6 __builtin_amdgcn_cvt_scalef32_sr_pk32_fp6_f32(float32, int, float) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cvt.scalef32.sr.pk.fp4.f32")
    int __builtin_amdgcn_cvt_scalef32_sr_pk_fp4_f32(int, float2, int, float, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cvt.sr.bf8.f32")
    int __builtin_amdgcn_cvt_sr_bf8_f32(float, int, int, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.cvt.sr.fp8.f32")
    int __builtin_amdgcn_cvt_sr_fp8_f32(float, int, int, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.dispatch.id")
    long __builtin_amdgcn_dispatch_id();

pragma(LDC_intrinsic, "llvm.amdgcn.dot4.f32.bf8.bf8")
    float __builtin_amdgcn_dot4_f32_bf8_bf8(int, int, float) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.dot4.f32.bf8.fp8")
    float __builtin_amdgcn_dot4_f32_bf8_fp8(int, int, float) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.dot4.f32.fp8.bf8")
    float __builtin_amdgcn_dot4_f32_fp8_bf8(int, int, float) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.dot4.f32.fp8.fp8")
    float __builtin_amdgcn_dot4_f32_fp8_fp8(int, int, float) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.ds.atomic.async.barrier.arrive.b64")
    void __builtin_amdgcn_ds_atomic_async_barrier_arrive_b64(void*);

pragma(LDC_intrinsic, "llvm.amdgcn.ds.atomic.barrier.arrive.rtn.b64")
    long __builtin_amdgcn_ds_atomic_barrier_arrive_rtn_b64(void*, long);

pragma(LDC_intrinsic, "llvm.amdgcn.ds.bpermute")
    int __builtin_amdgcn_ds_bpermute(int, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.ds.bpermute.fi.b32")
    int __builtin_amdgcn_ds_bpermute_fi_b32(int, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.ds.gws.barrier")
    void __builtin_amdgcn_ds_gws_barrier(int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.ds.gws.init")
    void __builtin_amdgcn_ds_gws_init(int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.ds.gws.sema.br")
    void __builtin_amdgcn_ds_gws_sema_br(int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.ds.gws.sema.p")
    void __builtin_amdgcn_ds_gws_sema_p(int);

pragma(LDC_intrinsic, "llvm.amdgcn.ds.gws.sema.release.all")
    void __builtin_amdgcn_ds_gws_sema_release_all(int);

pragma(LDC_intrinsic, "llvm.amdgcn.ds.gws.sema.v")
    void __builtin_amdgcn_ds_gws_sema_v(int);

pragma(LDC_intrinsic, "llvm.amdgcn.ds.permute")
    int __builtin_amdgcn_ds_permute(int, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.ds.swizzle")
    int __builtin_amdgcn_ds_swizzle(int, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.endpgm")
    void __builtin_amdgcn_endpgm();

pragma(LDC_intrinsic, "llvm.amdgcn.fmul.legacy")
    float __builtin_amdgcn_fmul_legacy(float, float) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.global.load.lds")
    void __builtin_amdgcn_global_load_lds(void*, void*, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.groupstaticsize")
    int __builtin_amdgcn_groupstaticsize();

pragma(LDC_intrinsic, "llvm.amdgcn.iglp.opt")
    void __builtin_amdgcn_iglp_opt(int);

pragma(LDC_intrinsic, "llvm.amdgcn.implicit.buffer.ptr")
    void* __builtin_amdgcn_implicit_buffer_ptr();

pragma(LDC_intrinsic, "llvm.amdgcn.implicitarg.ptr")
    void* __builtin_amdgcn_implicitarg_ptr();

pragma(LDC_intrinsic, "llvm.amdgcn.interp.mov")
    float __builtin_amdgcn_interp_mov(int, int, int, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.interp.p1")
    float __builtin_amdgcn_interp_p1(float, int, int, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.interp.p1.f16")
    float __builtin_amdgcn_interp_p1_f16(float, int, int, bool, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.interp.p2")
    float __builtin_amdgcn_interp_p2(float, float, int, int, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.is.private")
    bool __builtin_amdgcn_is_private(void*) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.is.shared")
    bool __builtin_amdgcn_is_shared(void*) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.kernarg.segment.ptr")
    void* __builtin_amdgcn_kernarg_segment_ptr();

pragma(LDC_intrinsic, "llvm.amdgcn.lerp")
    int __builtin_amdgcn_lerp(int, int, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.mbcnt.hi")
    int __builtin_amdgcn_mbcnt_hi(int, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.mbcnt.lo")
    int __builtin_amdgcn_mbcnt_lo(int, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.f32.16x16x16bf16.1k")
    float4 __builtin_amdgcn_mfma_f32_16x16x16bf16_1k(short4, short4, float4, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.f32.16x16x1f32")
    float16 __builtin_amdgcn_mfma_f32_16x16x1f32(float, float, float16, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.f32.16x16x2bf16")
    float16 __builtin_amdgcn_mfma_f32_16x16x2bf16(short2, short2, float16, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.f32.16x16x32.bf8.bf8")
    float4 __builtin_amdgcn_mfma_f32_16x16x32_bf8_bf8(long, long, float4, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.f32.16x16x32.bf8.fp8")
    float4 __builtin_amdgcn_mfma_f32_16x16x32_bf8_fp8(long, long, float4, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.f32.16x16x32.fp8.bf8")
    float4 __builtin_amdgcn_mfma_f32_16x16x32_fp8_bf8(long, long, float4, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.f32.16x16x32.fp8.fp8")
    float4 __builtin_amdgcn_mfma_f32_16x16x32_fp8_fp8(long, long, float4, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.f32.16x16x4bf16.1k")
    float16 __builtin_amdgcn_mfma_f32_16x16x4bf16_1k(short4, short4, float16, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.f32.16x16x4f32")
    float4 __builtin_amdgcn_mfma_f32_16x16x4f32(float, float, float4, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.f32.16x16x8.xf32")
    float4 __builtin_amdgcn_mfma_f32_16x16x8_xf32(float2, float2, float4, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.f32.16x16x8bf16")
    float4 __builtin_amdgcn_mfma_f32_16x16x8bf16(short2, short2, float4, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.f32.32x32x16.bf8.bf8")
    float16 __builtin_amdgcn_mfma_f32_32x32x16_bf8_bf8(long, long, float16, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.f32.32x32x16.bf8.fp8")
    float16 __builtin_amdgcn_mfma_f32_32x32x16_bf8_fp8(long, long, float16, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.f32.32x32x16.fp8.bf8")
    float16 __builtin_amdgcn_mfma_f32_32x32x16_fp8_bf8(long, long, float16, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.f32.32x32x16.fp8.fp8")
    float16 __builtin_amdgcn_mfma_f32_32x32x16_fp8_fp8(long, long, float16, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.f32.32x32x1f32")
    float32 __builtin_amdgcn_mfma_f32_32x32x1f32(float, float, float32, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.f32.32x32x2bf16")
    float32 __builtin_amdgcn_mfma_f32_32x32x2bf16(short2, short2, float32, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.f32.32x32x2f32")
    float16 __builtin_amdgcn_mfma_f32_32x32x2f32(float, float, float16, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.f32.32x32x4.xf32")
    float16 __builtin_amdgcn_mfma_f32_32x32x4_xf32(float2, float2, float16, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.f32.32x32x4bf16")
    float16 __builtin_amdgcn_mfma_f32_32x32x4bf16(short2, short2, float16, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.f32.32x32x4bf16.1k")
    float32 __builtin_amdgcn_mfma_f32_32x32x4bf16_1k(short4, short4, float32, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.f32.32x32x8bf16.1k")
    float16 __builtin_amdgcn_mfma_f32_32x32x8bf16_1k(short4, short4, float16, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.f32.4x4x1f32")
    float4 __builtin_amdgcn_mfma_f32_4x4x1f32(float, float, float4, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.f32.4x4x2bf16")
    float4 __builtin_amdgcn_mfma_f32_4x4x2bf16(short2, short2, float4, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.f32.4x4x4bf16.1k")
    float4 __builtin_amdgcn_mfma_f32_4x4x4bf16_1k(short4, short4, float4, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.f64.16x16x4f64")
    double4 __builtin_amdgcn_mfma_f64_16x16x4f64(double, double, double4, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.f64.4x4x4f64")
    double __builtin_amdgcn_mfma_f64_4x4x4f64(double, double, double, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.i32.16x16x16i8")
    int4 __builtin_amdgcn_mfma_i32_16x16x16i8(int, int, int4, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.i32.16x16x32.i8")
    int4 __builtin_amdgcn_mfma_i32_16x16x32_i8(long, long, int4, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.i32.16x16x4i8")
    int16 __builtin_amdgcn_mfma_i32_16x16x4i8(int, int, int16, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.i32.16x16x64.i8")
    int4 __builtin_amdgcn_mfma_i32_16x16x64_i8(int4, int4, int4, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.i32.32x32x16.i8")
    int16 __builtin_amdgcn_mfma_i32_32x32x16_i8(long, long, int16, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.i32.32x32x32.i8")
    int16 __builtin_amdgcn_mfma_i32_32x32x32_i8(int4, int4, int16, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.i32.32x32x4i8")
    int32 __builtin_amdgcn_mfma_i32_32x32x4i8(int, int, int32, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.i32.32x32x8i8")
    int16 __builtin_amdgcn_mfma_i32_32x32x8i8(int, int, int16, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mfma.i32.4x4x4i8")
    int4 __builtin_amdgcn_mfma_i32_4x4x4i8(int, int, int4, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.mqsad.pk.u16.u8")
    long __builtin_amdgcn_mqsad_pk_u16_u8(long, int, long) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.mqsad.u32.u8")
    int4 __builtin_amdgcn_mqsad_u32_u8(long, int, int4) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.msad.u8")
    int __builtin_amdgcn_msad_u8(int, int, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.perm")
    int __builtin_amdgcn_perm(int, int, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.permlane16.var")
    int __builtin_amdgcn_permlane16_var(int, int, int, bool, bool) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.permlanex16.var")
    int __builtin_amdgcn_permlanex16_var(int, int, int, bool, bool) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.prng.b32")
    int __builtin_amdgcn_prng_b32(int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.qsad.pk.u16.u8")
    long __builtin_amdgcn_qsad_pk_u16_u8(long, int, long) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.queue.ptr")
    void* __builtin_amdgcn_queue_ptr();

pragma(LDC_intrinsic, "llvm.amdgcn.raw.ptr.buffer.load.lds")
    void __builtin_amdgcn_raw_ptr_buffer_load_lds(void*, void*, int, int, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.rcp.legacy")
    float __builtin_amdgcn_rcp_legacy(float) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.rsq.legacy")
    float __builtin_amdgcn_rsq_legacy(float) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.s.barrier")
    void __builtin_amdgcn_s_barrier() pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.s.barrier.signal")
    void __builtin_amdgcn_s_barrier_signal(int);

pragma(LDC_intrinsic, "llvm.amdgcn.s.barrier.signal.isfirst")
    bool __builtin_amdgcn_s_barrier_signal_isfirst(int);

pragma(LDC_intrinsic, "llvm.amdgcn.s.barrier.signal.var")
    void __builtin_amdgcn_s_barrier_signal_var(void*, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.s.barrier.wait")
    void __builtin_amdgcn_s_barrier_wait(short);

pragma(LDC_intrinsic, "llvm.amdgcn.s.buffer.prefetch.data")
    void __builtin_amdgcn_s_buffer_prefetch_data(void*, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.s.dcache.inv")
    void __builtin_amdgcn_s_dcache_inv() pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.s.dcache.inv.vol")
    void __builtin_amdgcn_s_dcache_inv_vol() pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.s.dcache.wb")
    void __builtin_amdgcn_s_dcache_wb() pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.s.dcache.wb.vol")
    void __builtin_amdgcn_s_dcache_wb_vol() pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.s.decperflevel")
    void __builtin_amdgcn_s_decperflevel(int);

pragma(LDC_intrinsic, "llvm.amdgcn.s.get.barrier.state")
    int __builtin_amdgcn_s_get_barrier_state(int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.s.get.named.barrier.state")
    int __builtin_amdgcn_s_get_named_barrier_state(void*) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.s.get.waveid.in.workgroup")
    int __builtin_amdgcn_s_get_waveid_in_workgroup();

pragma(LDC_intrinsic, "llvm.amdgcn.s.getpc")
    long __builtin_amdgcn_s_getpc();

pragma(LDC_intrinsic, "llvm.amdgcn.s.getreg")
    int __builtin_amdgcn_s_getreg(int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.s.incperflevel")
    void __builtin_amdgcn_s_incperflevel(int);

pragma(LDC_intrinsic, "llvm.amdgcn.s.memrealtime")
    long __builtin_amdgcn_s_memrealtime() pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.s.memtime")
    long __builtin_amdgcn_s_memtime() pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.s.monitor.sleep")
    void __builtin_amdgcn_s_monitor_sleep(short);

pragma(LDC_intrinsic, "llvm.amdgcn.s.sendmsg")
    void __builtin_amdgcn_s_sendmsg(int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.s.sendmsghalt")
    void __builtin_amdgcn_s_sendmsghalt(int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.s.setprio")
    void __builtin_amdgcn_s_setprio(short);

pragma(LDC_intrinsic, "llvm.amdgcn.s.setprio.inc.wg")
    void __builtin_amdgcn_s_setprio_inc_wg(short);

pragma(LDC_intrinsic, "llvm.amdgcn.s.setreg")
    void __builtin_amdgcn_s_setreg(int, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.s.sleep")
    void __builtin_amdgcn_s_sleep(int);

pragma(LDC_intrinsic, "llvm.amdgcn.s.sleep.var")
    void __builtin_amdgcn_s_sleep_var(int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.s.ttracedata")
    void __builtin_amdgcn_s_ttracedata(int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.s.ttracedata.imm")
    void __builtin_amdgcn_s_ttracedata_imm(short) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.s.wait.asynccnt")
    void __builtin_amdgcn_s_wait_asynccnt(short);

pragma(LDC_intrinsic, "llvm.amdgcn.s.wait.event.export.ready")
    void __builtin_amdgcn_s_wait_event_export_ready() pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.s.wait.tensorcnt")
    void __builtin_amdgcn_s_wait_tensorcnt(short);

pragma(LDC_intrinsic, "llvm.amdgcn.s.waitcnt")
    void __builtin_amdgcn_s_waitcnt(int);

pragma(LDC_intrinsic, "llvm.amdgcn.sad.hi.u8")
    int __builtin_amdgcn_sad_hi_u8(int, int, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.sad.u16")
    int __builtin_amdgcn_sad_u16(int, int, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.sad.u8")
    int __builtin_amdgcn_sad_u8(int, int, int) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.sched.barrier")
    void __builtin_amdgcn_sched_barrier(int);

pragma(LDC_intrinsic, "llvm.amdgcn.sched.group.barrier")
    void __builtin_amdgcn_sched_group_barrier(int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.sdot2")
    int __builtin_amdgcn_sdot2(short2, short2, int, bool) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.sdot4")
    int __builtin_amdgcn_sdot4(int, int, int, bool) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.sdot8")
    int __builtin_amdgcn_sdot8(int, int, int, bool) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.smfmac.f32.16x16x128.bf8.bf8")
    float4 __builtin_amdgcn_smfmac_f32_16x16x128_bf8_bf8(int4, int8, float4, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.smfmac.f32.16x16x128.bf8.fp8")
    float4 __builtin_amdgcn_smfmac_f32_16x16x128_bf8_fp8(int4, int8, float4, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.smfmac.f32.16x16x128.fp8.bf8")
    float4 __builtin_amdgcn_smfmac_f32_16x16x128_fp8_bf8(int4, int8, float4, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.smfmac.f32.16x16x128.fp8.fp8")
    float4 __builtin_amdgcn_smfmac_f32_16x16x128_fp8_fp8(int4, int8, float4, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.smfmac.f32.16x16x32.bf16")
    float4 __builtin_amdgcn_smfmac_f32_16x16x32_bf16(short4, short8, float4, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.smfmac.f32.16x16x64.bf8.bf8")
    float4 __builtin_amdgcn_smfmac_f32_16x16x64_bf8_bf8(int2, int4, float4, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.smfmac.f32.16x16x64.bf8.fp8")
    float4 __builtin_amdgcn_smfmac_f32_16x16x64_bf8_fp8(int2, int4, float4, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.smfmac.f32.16x16x64.fp8.bf8")
    float4 __builtin_amdgcn_smfmac_f32_16x16x64_fp8_bf8(int2, int4, float4, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.smfmac.f32.16x16x64.fp8.fp8")
    float4 __builtin_amdgcn_smfmac_f32_16x16x64_fp8_fp8(int2, int4, float4, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.smfmac.f32.32x32x16.bf16")
    float16 __builtin_amdgcn_smfmac_f32_32x32x16_bf16(short4, short8, float16, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.smfmac.f32.32x32x32.bf8.bf8")
    float16 __builtin_amdgcn_smfmac_f32_32x32x32_bf8_bf8(int2, int4, float16, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.smfmac.f32.32x32x32.bf8.fp8")
    float16 __builtin_amdgcn_smfmac_f32_32x32x32_bf8_fp8(int2, int4, float16, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.smfmac.f32.32x32x32.fp8.bf8")
    float16 __builtin_amdgcn_smfmac_f32_32x32x32_fp8_bf8(int2, int4, float16, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.smfmac.f32.32x32x32.fp8.fp8")
    float16 __builtin_amdgcn_smfmac_f32_32x32x32_fp8_fp8(int2, int4, float16, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.smfmac.f32.32x32x64.bf8.bf8")
    float16 __builtin_amdgcn_smfmac_f32_32x32x64_bf8_bf8(int4, int8, float16, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.smfmac.f32.32x32x64.bf8.fp8")
    float16 __builtin_amdgcn_smfmac_f32_32x32x64_bf8_fp8(int4, int8, float16, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.smfmac.f32.32x32x64.fp8.bf8")
    float16 __builtin_amdgcn_smfmac_f32_32x32x64_fp8_bf8(int4, int8, float16, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.smfmac.f32.32x32x64.fp8.fp8")
    float16 __builtin_amdgcn_smfmac_f32_32x32x64_fp8_fp8(int4, int8, float16, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.smfmac.i32.16x16x128.i8")
    int4 __builtin_amdgcn_smfmac_i32_16x16x128_i8(int4, int8, int4, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.smfmac.i32.16x16x64.i8")
    int4 __builtin_amdgcn_smfmac_i32_16x16x64_i8(int2, int4, int4, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.smfmac.i32.32x32x32.i8")
    int16 __builtin_amdgcn_smfmac_i32_32x32x32_i8(int2, int4, int16, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.smfmac.i32.32x32x64.i8")
    int16 __builtin_amdgcn_smfmac_i32_32x32x64_i8(int4, int8, int16, int, int, int);

pragma(LDC_intrinsic, "llvm.amdgcn.sudot4")
    int __builtin_amdgcn_sudot4(bool, int, bool, int, int, bool) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.sudot8")
    int __builtin_amdgcn_sudot8(bool, int, bool, int, int, bool) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.tensor.load.to.lds")
    void __builtin_amdgcn_tensor_load_to_lds(int4, int8, int4, int4, int);

pragma(LDC_intrinsic, "llvm.amdgcn.tensor.load.to.lds.d2")
    void __builtin_amdgcn_tensor_load_to_lds_d2(int4, int8, int);

pragma(LDC_intrinsic, "llvm.amdgcn.tensor.store.from.lds")
    void __builtin_amdgcn_tensor_store_from_lds(int4, int8, int4, int4, int);

pragma(LDC_intrinsic, "llvm.amdgcn.tensor.store.from.lds.d2")
    void __builtin_amdgcn_tensor_store_from_lds_d2(int4, int8, int);

pragma(LDC_intrinsic, "llvm.amdgcn.udot2")
    int __builtin_amdgcn_udot2(short2, short2, int, bool) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.udot4")
    int __builtin_amdgcn_udot4(int, int, int, bool) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.udot8")
    int __builtin_amdgcn_udot8(int, int, int, bool) pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.wave.barrier")
    void __builtin_amdgcn_wave_barrier() pure @safe;

pragma(LDC_intrinsic, "llvm.amdgcn.wavefrontsize")
    int __builtin_amdgcn_wavefrontsize();

pragma(LDC_intrinsic, "llvm.amdgcn.workgroup.id.x")
    int __builtin_amdgcn_workgroup_id_x();

pragma(LDC_intrinsic, "llvm.amdgcn.workgroup.id.y")
    int __builtin_amdgcn_workgroup_id_y();

pragma(LDC_intrinsic, "llvm.amdgcn.workgroup.id.z")
    int __builtin_amdgcn_workgroup_id_z();

pragma(LDC_intrinsic, "llvm.amdgcn.workitem.id.x")
    int __builtin_amdgcn_workitem_id_x();

pragma(LDC_intrinsic, "llvm.amdgcn.workitem.id.y")
    int __builtin_amdgcn_workitem_id_y();

pragma(LDC_intrinsic, "llvm.amdgcn.workitem.id.z")
    int __builtin_amdgcn_workitem_id_z();

