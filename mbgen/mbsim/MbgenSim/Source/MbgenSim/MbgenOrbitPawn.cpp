#include "MbgenOrbitPawn.h"
#include "Camera/CameraComponent.h"
#include "MbgenStore.h"

AMbgenOrbitPawn::AMbgenOrbitPawn()
{
    Pivot = CreateDefaultSubobject<USceneComponent>(TEXT("Pivot"));
    RootComponent = Pivot;
    Camera = CreateDefaultSubobject<UCameraComponent>(TEXT("Camera"));
    Camera->SetupAttachment(Pivot);
    PlaceCamera();
}

void AMbgenOrbitPawn::AddOrbit(float YawDelta, float PitchDelta)
{
    const float S = FMbgenStore::MouseSens();
    Yaw += YawDelta * S;
    Pitch = FMath::Clamp(Pitch + PitchDelta * S, -85.f, 85.f);
    PlaceCamera();
}

void AMbgenOrbitPawn::AddPan(float RightDelta, float UpDelta)
{
    const FRotationMatrix M(FRotator(Pitch, Yaw, 0.f));
    const float Step = FMath::Max(Distance, 30.f) * 0.0022f * FMbgenStore::MouseSens();
    AddActorWorldOffset(M.GetUnitAxis(EAxis::Y) * RightDelta * Step + M.GetUnitAxis(EAxis::Z) * UpDelta * Step);
}

void AMbgenOrbitPawn::AddZoom(float Notches)
{
    Distance = FMbgenStore::ZoomDistance(Distance, Notches);
    PlaceCamera();
}

void AMbgenOrbitPawn::OrbitAbout(const FVector& WorldPivot)
{
    const FVector Cam = Camera->GetComponentLocation();
    SetActorLocation(WorldPivot);
    const FVector Rel = Cam - WorldPivot;
    Distance = FMath::Clamp(Rel.Size(), 20.f, 8000.f);
    const FRotator Look = (WorldPivot - Cam).Rotation();
    Yaw = Look.Yaw;
    Pitch = FMath::Clamp(Look.Pitch, -85.f, 85.f);
    PlaceCamera();
}

void AMbgenOrbitPawn::AddZoomToward(const FVector& WorldHit, float Notches)
{
    const FVector Cam = Camera->GetComponentLocation();
    const FVector LookDir = FRotator(Pitch, Yaw, 0.f).Vector();
    FVector Rel = Cam - WorldHit;
    const float Dist = FMath::Max(Rel.Size(), 1.f);
    const float NewDist = FMbgenStore::ZoomDistance(Dist, Notches);
    const FVector NewCam = WorldHit + Rel.GetSafeNormal() * NewDist;
    SetActorLocation(NewCam + LookDir * Distance);
    PlaceCamera();
}

void AMbgenOrbitPawn::AddLook(float YawDelta, float PitchDelta)
{
    const FVector Cam = Camera->GetComponentLocation();
    const FRotationMatrix M(FRotator(Pitch, Yaw, 0.f));
    FVector Forward = M.GetUnitAxis(EAxis::X);
    const FVector Right = M.GetUnitAxis(EAxis::Y);
    const float S = FMbgenStore::MouseSens();
    Forward = Forward.RotateAngleAxis(YawDelta * S, FVector::UpVector);
    Forward = Forward.RotateAngleAxis(PitchDelta * S, Right);
    Forward.Normalize();
    const FRotator Look = Forward.Rotation();
    Yaw = Look.Yaw;
    Pitch = FMath::Clamp(Look.Pitch, -85.f, 85.f);
    const FVector PinnedFwd = FRotator(Pitch, Yaw, 0.f).Vector();
    SetActorLocation(Cam + PinnedFwd * Distance);
    PlaceCamera();
}

void AMbgenOrbitPawn::PlaceCamera()
{
    const FRotator Rot(Pitch, Yaw, 0.f);
    Camera->SetRelativeLocation(Rot.Vector() * -Distance);
    Camera->SetRelativeRotation(Rot);
}
