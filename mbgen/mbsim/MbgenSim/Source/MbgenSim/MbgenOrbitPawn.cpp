#include "MbgenOrbitPawn.h"
#include "Camera/CameraComponent.h"
#include "MbgenNav.h"
#include "MbgenStore.h"

AMbgenOrbitPawn::AMbgenOrbitPawn()
{
    Root = CreateDefaultSubobject<USceneComponent>(TEXT("Root"));
    RootComponent = Root;
    Camera = CreateDefaultSubobject<UCameraComponent>(TEXT("Camera"));
    Camera->SetupAttachment(Root);
    // Camera sits at the actor; the actor location IS the camera location.
    const FRotator Rot(Pitch, Yaw, 0.f);
    SetActorLocation(OrbitPivot - Rot.Vector() * Distance);
    Camera->SetRelativeLocation(FVector::ZeroVector);
    Camera->SetRelativeRotation(Rot);
}

FVector AMbgenOrbitPawn::CameraLocation() const
{
    return GetActorLocation();
}

FVector AMbgenOrbitPawn::Forward() const
{
    return FRotator(Pitch, Yaw, 0.f).Vector();
}

void AMbgenOrbitPawn::Pose(const FVector& CamLoc, const FVector& ForwardDir)
{
    const FRotator Rot = FMbgenNav::LevelLook(ForwardDir);
    Yaw = Rot.Yaw;
    Pitch = Rot.Pitch;
    SetActorLocation(CamLoc);
    Camera->SetRelativeLocation(FVector::ZeroVector);
    Camera->SetRelativeRotation(Rot);
}

void AMbgenOrbitPawn::AddOrbit(float YawDelta, float PitchDelta)
{
    const float S = FMbgenStore::MouseSens();
    FVector Fwd;
    const FVector Cam = FMbgenNav::Orbit(OrbitPivot, CameraLocation(), YawDelta * S, PitchDelta * S, Fwd);
    Pose(Cam, Fwd);
}

void AMbgenOrbitPawn::AddPan(float RightDelta, float UpDelta)
{
    // Editor pan law (grab-and-drag): camera moves against the cursor along
    // camera right, with it along camera up for a screen-down delta; the step
    // scales with distance to the pivot; camera and pivot move together.
    // UpDelta is screen-down-positive (the controller passes -MouseY).
    const FRotationMatrix M(FRotator(Pitch, Yaw, 0.f));
    const float Step = FMath::Max((CameraLocation() - OrbitPivot).Size(), 20.f) * 0.0011f * FMbgenStore::MouseSens();
    const FVector Move = M.GetUnitAxis(EAxis::Y) * -RightDelta * Step + M.GetUnitAxis(EAxis::Z) * UpDelta * Step;
    OrbitPivot += Move;
    Pose(CameraLocation() + Move, Forward());
}

void AMbgenOrbitPawn::AddZoom(float Notches)
{
    AddZoomToward(OrbitPivot, Notches);
}

void AMbgenOrbitPawn::OrbitAbout(const FVector& WorldPivot)
{
    OrbitPivot = WorldPivot;
    const FVector Cam = CameraLocation();
    const FVector Toward = (OrbitPivot - Cam).GetSafeNormal(1e-6, Forward());
    Pose(Cam, Toward);
}

void AMbgenOrbitPawn::SetPivot(const FVector& WorldPivot)
{
    OrbitPivot = WorldPivot;
}

void AMbgenOrbitPawn::AddZoomToward(const FVector& WorldHit, float Notches)
{
    const FVector Cam = FMbgenNav::ZoomToward(CameraLocation(), WorldHit, Notches, FMbgenStore::MouseSens());
    OrbitPivot = WorldHit;
    Pose(Cam, Forward());
}

void AMbgenOrbitPawn::AddLook(float YawDelta, float PitchDelta)
{
    const float S = FMbgenStore::MouseSens();
    const FVector Fwd = FMbgenNav::Look(Forward(), YawDelta * S, PitchDelta * S);
    Pose(CameraLocation(), Fwd);
}

void AMbgenOrbitPawn::FrameOn(const FVector& WorldPivot)
{
    OrbitPivot = WorldPivot;
    const FVector Cam = CameraLocation();
    float Dist = (Cam - OrbitPivot).Size();
    if (Dist < 12.f) { Dist = Distance; }
    const FVector Dir = (Cam - OrbitPivot).GetSafeNormal(1e-6, -Forward());
    const FVector NewCam = OrbitPivot + Dir * Dist;
    Pose(NewCam, (OrbitPivot - NewCam).GetSafeNormal());
}
