#include "MbgenGameMode.h"
#include "MbgenBoardActor.h"
#include "MbgenOrbitPawn.h"
#include "MbgenPlayerController.h"
#include "EngineUtils.h"

AMbgenGameMode::AMbgenGameMode()
{
    DefaultPawnClass = AMbgenOrbitPawn::StaticClass();
    PlayerControllerClass = AMbgenPlayerController::StaticClass();
}

void AMbgenGameMode::StartPlay()
{
    Super::StartPlay();
    UWorld* World = GetWorld();
    if (!World) { return; }
    AMbgenBoardActor* Board = AMbgenBoardActor::FindLive(World);
    if (!Board)
    {
        Board = World->SpawnActor<AMbgenBoardActor>(FVector::ZeroVector, FRotator::ZeroRotator);
    }
    if (Board)
    {
        Board->FrameOrbit();
    }
}
