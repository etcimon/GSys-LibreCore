#include "MbgenSim.h"
#include "Modules/ModuleManager.h"
#if WITH_EDITOR
#include "MbgenEditorBridge.h"
#endif

void FMbgenSimModule::StartupModule()
{
#if WITH_EDITOR
    FMbgenEditorBridge::Start();
#endif
}

void FMbgenSimModule::ShutdownModule()
{
#if WITH_EDITOR
    FMbgenEditorBridge::Stop();
#endif
}

IMPLEMENT_PRIMARY_GAME_MODULE(FMbgenSimModule, MbgenSim, "MbgenSim");
