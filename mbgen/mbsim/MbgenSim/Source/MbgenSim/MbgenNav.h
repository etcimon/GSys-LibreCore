#pragma once
#include "CoreMinimal.h"

/* One navigation law for the editor viewport and the standalone pawn.
   The math lives in mbcore (Rust, `nav.rs`) and is reached through the
   mbcore_c `mb_nav_*` exports. When the DLL is not loaded the helper runs a
   clearly labelled reduced mode (the pre-existing local math) and says so
   once in the log; it never grows a third independent implementation.

   Units are whatever the caller passes (world centimetres in practice);
   the law is unit-agnostic. A desk is {cx, cy, z, hx, hy}. */
struct MBGENSIM_API FMbgenNavDesk
{
    double V[5] = { 0.0, 0.0, 0.0, 0.0, 0.0 };
};

class MBGENSIM_API FMbgenNav
{
public:
    /* Bind `mb_nav_*` from an already loaded mbcore_c handle. Missing exports
       leave the helper in reduced mode. */
    static void BindFromDll(void* DllHandle);
    static void Unbind();
    static bool IsDll();
    static const TCHAR* ModeName();

    static FMbgenNavDesk Desk(double BoardWCm, double BoardDCm, double ZCm);
    /* Empty-click orbit / dolly pivot. Never a clamped rim corner. */
    static FVector PickPivot(const FMbgenNavDesk& Desk, const FVector& Cam, const FVector& Dir, const FVector& LastPivot);
    /* Camera on a sphere about Pivot, looking at it, roll 0. Returns the new camera; OutForward looks at Pivot. */
    static FVector Orbit(const FVector& Pivot, const FVector& Cam, double YawDeg, double PitchDeg, FVector& OutForward);
    /* Camera fixed; yaw about world Z, pitch about camera right; roll 0. */
    static FVector Look(const FVector& Forward, double YawDeg, double PitchDeg);
    /* Dolly along the pick ray by clamped wheel notches. */
    static FVector ZoomToward(const FVector& Cam, const FVector& Hit, double Notches, double Sens);
    static double ZoomDistance(double Dist, double Notches, double Sens);
    /* Roll 0, pitch clamped to the law's +-85 degrees. */
    static FRotator LevelLook(const FVector& Forward);
};
