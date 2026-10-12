#pragma once
#include "CoreMinimal.h"
#include "GameFramework/Pawn.h"
#include "MbgenOrbitPawn.generated.h"

class UCameraComponent;

UCLASS()
class MBGENSIM_API AMbgenOrbitPawn : public APawn
{
    GENERATED_BODY()
public:
    AMbgenOrbitPawn();
    void AddOrbit(float YawDelta, float PitchDelta);
    void AddPan(float RightDelta, float UpDelta);
    void AddZoom(float Notches);
    void OrbitAbout(const FVector& WorldPivot);
    void AddZoomToward(const FVector& WorldHit, float Notches);
    void AddLook(float YawDelta, float PitchDelta);
    UPROPERTY(EditAnywhere, Category = "mbgen")
    float Distance = 1600.f;
private:
    UPROPERTY()
    TObjectPtr<USceneComponent> Pivot;
    UPROPERTY()
    TObjectPtr<UCameraComponent> Camera;
    float Yaw = 35.f;
    float Pitch = -28.f;
    void PlaceCamera();
};
