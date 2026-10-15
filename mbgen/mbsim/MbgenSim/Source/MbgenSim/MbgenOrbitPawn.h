#pragma once
#include "CoreMinimal.h"
#include "GameFramework/Pawn.h"
#include "MbgenOrbitPawn.generated.h"

class UCameraComponent;

/* Standalone camera. State is explicit — camera location, yaw/pitch, orbit
   pivot — exactly the editor viewport's state, and every motion law is the
   shared FMbgenNav one. The pivot is not required to sit on the camera's
   forward axis (a wheel toward an off-centre part keeps rotation and moves
   the pivot to the pick, as the editor does). */
UCLASS()
class MBGENSIM_API AMbgenOrbitPawn : public APawn
{
    GENERATED_BODY()
public:
    AMbgenOrbitPawn();
    void AddOrbit(float YawDelta, float PitchDelta);
    void AddPan(float RightDelta, float UpDelta);
    void AddZoom(float Notches);
    /* Right-button down: set the orbit centre and aim at it; camera stays put. */
    void OrbitAbout(const FVector& WorldPivot);
    /* Wheel: dolly along the pick ray, rotation kept, pivot = pick. */
    void AddZoomToward(const FVector& WorldHit, float Notches);
    /* Left-drag on empty space: rotate in place; camera stays put. */
    void AddLook(float YawDelta, float PitchDelta);
    /* Set the pivot without moving or re-aiming the camera (look start). */
    void SetPivot(const FVector& WorldPivot);
    /* F / BeginPlay: pivot = target, keep distance, aim at it. */
    void FrameOn(const FVector& WorldPivot);
    FVector CameraLocation() const;
    FVector Forward() const;
    const FVector& Pivot() const { return OrbitPivot; }
    /* Initial / framing distance from the pivot, in world units. */
    UPROPERTY(EditAnywhere, Category = "mbgen")
    float Distance = 1600.f;
private:
    UPROPERTY()
    TObjectPtr<USceneComponent> Root;
    UPROPERTY()
    TObjectPtr<UCameraComponent> Camera;
    FVector OrbitPivot = FVector::ZeroVector;
    float Yaw = 35.f;
    float Pitch = -28.f;
    void Pose(const FVector& CamLoc, const FVector& ForwardDir);
};
