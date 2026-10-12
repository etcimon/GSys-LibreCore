#pragma once
#include "CoreMinimal.h"
#include "MbgenSettings.generated.h"

UCLASS(config=Mbgen)
class MBGENSIM_API UMbgenSettings : public UObject
{
    GENERATED_BODY()
public:
    UPROPERTY(config, EditAnywhere, Category = "mbgen")
    FString Design = TEXT("Boards/design.json");

    UPROPERTY(config, EditAnywhere, Category = "mbgen")
    FString Scene = TEXT("Boards/scene.json");

    UPROPERTY(config, EditAnywhere, Category = "mbgen")
    bool LiveRouting = false;

    UPROPERTY(config, EditAnywhere, Category = "mbgen")
    int32 LiveRouteHz = 10;

    UPROPERTY(config, EditAnywhere, Category = "mbgen")
    FString DllPath;

    UPROPERTY(config, EditAnywhere, Category = "mbgen")
    FString LengthUnit = TEXT("mm");

    UPROPERTY(config, EditAnywhere, Category = "mbgen")
    float MouseSensitivity = 0.25f;
};
