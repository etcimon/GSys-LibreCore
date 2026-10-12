#pragma once
#include "CoreMinimal.h"
#include "GameFramework/GameModeBase.h"
#include "MbgenGameMode.generated.h"

UCLASS()
class MBGENSIM_API AMbgenGameMode : public AGameModeBase
{
    GENERATED_BODY()
public:
    AMbgenGameMode();
    virtual void StartPlay() override;
};
