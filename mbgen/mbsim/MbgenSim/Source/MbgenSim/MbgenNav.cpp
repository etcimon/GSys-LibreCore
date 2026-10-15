#include "MbgenNav.h"
#include "HAL/PlatformProcess.h"

namespace
{
    using DeskFn = int(*)(double, double, double, double*);
    using PickFn = int(*)(const double*, const double*, const double*, const double*, double*);
    using OrbitFn = int(*)(const double*, const double*, double, double, double*, double*);
    using LookFn = int(*)(const double*, double, double, double*);
    using ZoomTowardFn = int(*)(const double*, const double*, double, double, double*);
    using ZoomDistFn = double(*)(double, double, double);

    DeskFn GDesk = nullptr;
    PickFn GPick = nullptr;
    OrbitFn GOrbit = nullptr;
    LookFn GLook = nullptr;
    ZoomTowardFn GZoomToward = nullptr;
    ZoomDistFn GZoomDist = nullptr;
    bool GDll = false;
    bool GReducedLogged = false;

    // Reduced-mode constants mirror mbcore/src/nav.rs. They are only reached
    // when mbcore_c is absent, and the log says so.
    constexpr double ZoomRatio = 1.04;
    constexpr double WheelNotchLimit = 1.0;
    constexpr double MinDist = 20.0;
    constexpr double MaxDist = 8000.0;
    constexpr double PitchLimit = 85.0;

    void NoteReduced()
    {
        if (GReducedLogged) { return; }
        GReducedLogged = true;
        UE_LOG(LogTemp, Warning, TEXT("mbgen nav=local (reduced: mbcore_c mb_nav_* not bound)"));
    }

    void ToArr(const FVector& V, double* Out) { Out[0] = V.X; Out[1] = V.Y; Out[2] = V.Z; }
    FVector FromArr(const double* In) { return FVector(In[0], In[1], In[2]); }

    FVector LocalLook(const FVector& Forward, double YawDeg, double PitchDeg)
    {
        FVector F = Forward.GetSafeNormal(1e-9, FVector(0, 0, 1));
        F = F.RotateAngleAxis(YawDeg, FVector::UpVector);
        FVector Right = FVector::CrossProduct(F, FVector::UpVector);
        if (Right.SizeSquared() < 1e-12) { Right = FVector(1, 0, 0); }
        Right.Normalize();
        FVector Pitched = F * FMath::Cos(FMath::DegreesToRadians(PitchDeg)) + FVector::CrossProduct(Right, F) * FMath::Sin(FMath::DegreesToRadians(PitchDeg));
        const double LenXY = FMath::Sqrt(Pitched.X * Pitched.X + Pitched.Y * Pitched.Y);
        const double P = FMath::RadiansToDegrees(FMath::Atan2(Pitched.Z, LenXY));
        if (FMath::Abs(P) <= PitchLimit) { return Pitched.GetSafeNormal(); }
        const double Clamped = FMath::DegreesToRadians(FMath::Clamp(P, -PitchLimit, PitchLimit));
        FVector XY(Pitched.X, Pitched.Y, 0.0);
        XY = XY.GetSafeNormal(1e-9, FVector(1, 0, 0));
        return (XY * FMath::Cos(Clamped) + FVector(0, 0, FMath::Sin(Clamped))).GetSafeNormal();
    }
}

void FMbgenNav::BindFromDll(void* DllHandle)
{
    Unbind();
    if (!DllHandle) { return; }
    GDesk = (DeskFn)FPlatformProcess::GetDllExport(DllHandle, TEXT("mb_nav_desk"));
    GPick = (PickFn)FPlatformProcess::GetDllExport(DllHandle, TEXT("mb_nav_pick_pivot"));
    GOrbit = (OrbitFn)FPlatformProcess::GetDllExport(DllHandle, TEXT("mb_nav_orbit"));
    GLook = (LookFn)FPlatformProcess::GetDllExport(DllHandle, TEXT("mb_nav_look"));
    GZoomToward = (ZoomTowardFn)FPlatformProcess::GetDllExport(DllHandle, TEXT("mb_nav_zoom_toward"));
    GZoomDist = (ZoomDistFn)FPlatformProcess::GetDllExport(DllHandle, TEXT("mb_nav_zoom_distance"));
    GDll = GDesk && GPick && GOrbit && GLook && GZoomToward && GZoomDist;
    if (!GDll)
    {
        Unbind();
        UE_LOG(LogTemp, Warning, TEXT("mbgen nav=local (reduced: mbcore_c lacks mb_nav_* exports; rebuild the DLL)"));
        GReducedLogged = true;
        return;
    }
    UE_LOG(LogTemp, Display, TEXT("mbgen nav=mbcore_c"));
}

void FMbgenNav::Unbind()
{
    GDesk = nullptr; GPick = nullptr; GOrbit = nullptr; GLook = nullptr; GZoomToward = nullptr; GZoomDist = nullptr;
    GDll = false;
}

bool FMbgenNav::IsDll() { return GDll; }
const TCHAR* FMbgenNav::ModeName() { return GDll ? TEXT("mbcore_c") : TEXT("local"); }

FMbgenNavDesk FMbgenNav::Desk(double BoardWCm, double BoardDCm, double ZCm)
{
    FMbgenNavDesk D;
    if (GDll && GDesk(BoardWCm, BoardDCm, ZCm, D.V) == 0) { return D; }
    NoteReduced();
    D.V[0] = BoardWCm * 0.5; D.V[1] = BoardDCm * 0.5; D.V[2] = ZCm;
    D.V[3] = BoardWCm * 0.5 * 1.5; D.V[4] = BoardDCm * 0.5 * 1.5;
    return D;
}

FVector FMbgenNav::PickPivot(const FMbgenNavDesk& Desk, const FVector& Cam, const FVector& Dir, const FVector& LastPivot)
{
    double C[3], Dr[3], L[3], Out[3];
    ToArr(Cam, C); ToArr(Dir, Dr); ToArr(LastPivot, L);
    if (GDll && GPick(Desk.V, C, Dr, L, Out) == 0) { return FromArr(Out); }
    NoteReduced();
    const FVector D = Dir.GetSafeNormal(1e-9, FVector(0, 0, 1));
    if (FMath::Abs(D.Z) > 1e-8)
    {
        const double T = (Desk.V[2] - Cam.Z) / D.Z;
        if (T > 0.0)
        {
            const FVector P = Cam + D * T;
            const bool Inside = P.X >= Desk.V[0] - Desk.V[3] && P.X <= Desk.V[0] + Desk.V[3]
                && P.Y >= Desk.V[1] - Desk.V[4] && P.Y <= Desk.V[1] + Desk.V[4];
            if (Inside) { return P; }
        }
    }
    const double Depth = FMath::Clamp((LastPivot - Cam).Size(), MinDist, MaxDist);
    return Cam + D * Depth;
}

FVector FMbgenNav::Orbit(const FVector& Pivot, const FVector& Cam, double YawDeg, double PitchDeg, FVector& OutForward)
{
    double P[3], C[3], OutC[3], OutF[3];
    ToArr(Pivot, P); ToArr(Cam, C);
    if (GDll && GOrbit(P, C, YawDeg, PitchDeg, OutC, OutF) == 0)
    {
        OutForward = FromArr(OutF);
        return FromArr(OutC);
    }
    NoteReduced();
    const FVector Rel = Cam - Pivot;
    const double Dist = FMath::Max(Rel.Size(), 1.0);
    const FVector F = LocalLook((Pivot - Cam).GetSafeNormal(), YawDeg, PitchDeg);
    const FVector Next = Pivot - F * Dist;
    OutForward = (Pivot - Next).GetSafeNormal();
    return Next;
}

FVector FMbgenNav::Look(const FVector& Forward, double YawDeg, double PitchDeg)
{
    double F[3], Out[3];
    ToArr(Forward, F);
    if (GDll && GLook(F, YawDeg, PitchDeg, Out) == 0) { return FromArr(Out); }
    NoteReduced();
    return LocalLook(Forward, YawDeg, PitchDeg);
}

FVector FMbgenNav::ZoomToward(const FVector& Cam, const FVector& Hit, double Notches, double Sens)
{
    double C[3], H[3], Out[3];
    ToArr(Cam, C); ToArr(Hit, H);
    if (GDll && GZoomToward(C, H, Notches, Sens, Out) == 0) { return FromArr(Out); }
    NoteReduced();
    const FVector Rel = Cam - Hit;
    const double Dist = FMath::Max(Rel.Size(), 1.0);
    return Hit + Rel.GetSafeNormal() * ZoomDistance(Dist, Notches, Sens);
}

double FMbgenNav::ZoomDistance(double Dist, double Notches, double Sens)
{
    if (GDll) { return GZoomDist(Dist, Notches, Sens); }
    NoteReduced();
    const double N = FMath::Clamp(Notches, -WheelNotchLimit, WheelNotchLimit) * FMath::Clamp(Sens, 0.05, 2.0);
    return FMath::Clamp(Dist / FMath::Pow(ZoomRatio, N), MinDist, MaxDist);
}

FRotator FMbgenNav::LevelLook(const FVector& Forward)
{
    FRotator Rot = Forward.Rotation();
    Rot.Roll = 0.f;
    Rot.Pitch = FMath::Clamp(Rot.Pitch, -85.f, 85.f);
    return Rot;
}
