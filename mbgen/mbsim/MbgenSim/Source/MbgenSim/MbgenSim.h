#pragma once
#include "CoreMinimal.h"
#include "Modules/ModuleManager.h"

class FMbgenSimModule : public FDefaultGameModuleImpl
{
public:
    virtual void StartupModule() override;
    virtual void ShutdownModule() override;
};
