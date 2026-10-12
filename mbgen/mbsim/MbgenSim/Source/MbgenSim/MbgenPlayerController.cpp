#include "MbgenPlayerController.h"
#include "MbgenBoardActor.h"
#include "MbgenOrbitPawn.h"
#include "MbgenPackageWidget.h"
#include "MbgenLibraryWidget.h"
#include "MbgenOutlineWidget.h"
#include "MbgenPropertyWidget.h"
#include "MbgenChrome.h"
#include "MbgenStore.h"
#include "EngineUtils.h"
#include "Blueprint/UserWidget.h"
#include "Framework/Application/SlateApplication.h"
#include "Engine/Engine.h"
#include "Engine/GameViewportClient.h"

void AMbgenPlayerController::BeginPlay()
{
    Super::BeginPlay();
    bShowMouseCursor = true;
    PrimaryActorTick.bCanEverTick = true;
    SetActorTickEnabled(true);
    if (AMbgenBoardActor* B = Board())
    {
        B->FrameOrbit();
    }
    ChromeBar = CreateWidget<UMbgenChromeWidget>(this, UMbgenChromeWidget::StaticClass());
    if (ChromeBar)
    {
        ChromeBar->AddToViewport(30);
        FVector2D Size(1280.f, 720.f);
        if (GEngine && GEngine->GameViewport) { GEngine->GameViewport->GetViewportSize(Size); }
        ChromeBar->SetPositionInViewport(FVector2D(FMath::Max(8.f, Size.X - 430.f), 8.f), false);
    }
}

void AMbgenPlayerController::SetupInputComponent()
{
    Super::SetupInputComponent();
    InputComponent->BindKey(EKeys::LeftMouseButton, IE_Pressed, this, &AMbgenPlayerController::SelectUnderCursor);
    InputComponent->BindKey(EKeys::LeftMouseButton, IE_Released, this, &AMbgenPlayerController::PlaceReleased);
    InputComponent->BindKey(EKeys::RightMouseButton, IE_Pressed, this, &AMbgenPlayerController::OrbitPressed);
    InputComponent->BindKey(EKeys::RightMouseButton, IE_Released, this, &AMbgenPlayerController::OrbitReleased);
    InputComponent->BindKey(EKeys::MiddleMouseButton, IE_Pressed, this, &AMbgenPlayerController::PanPressed);
    InputComponent->BindKey(EKeys::MiddleMouseButton, IE_Released, this, &AMbgenPlayerController::PanReleased);
    InputComponent->BindKey(EKeys::MouseScrollUp, IE_Pressed, this, &AMbgenPlayerController::ZoomIn);
    InputComponent->BindKey(EKeys::MouseScrollDown, IE_Pressed, this, &AMbgenPlayerController::ZoomOut);
    InputComponent->BindKey(EKeys::C, IE_Pressed, this, &AMbgenPlayerController::TogglePackages);
    InputComponent->BindKey(EKeys::L, IE_Pressed, this, &AMbgenPlayerController::ToggleLibrary);
    InputComponent->BindKey(EKeys::T, IE_Pressed, this, &AMbgenPlayerController::ToggleOutline);
    InputComponent->BindKey(EKeys::P, IE_Pressed, this, &AMbgenPlayerController::ToggleProperties);
    InputComponent->BindKey(EKeys::B, IE_Pressed, this, &AMbgenPlayerController::ToggleBottom);
    InputComponent->BindKey(EKeys::F, IE_Pressed, this, &AMbgenPlayerController::FramePressed);
    InputComponent->BindKey(EKeys::Enter, IE_Pressed, this, &AMbgenPlayerController::CompilePressed);
    InputComponent->BindKey(EKeys::Delete, IE_Pressed, this, &AMbgenPlayerController::DeletePressed);
    InputComponent->BindKey(EKeys::Left, IE_Pressed, this, &AMbgenPlayerController::NudgeLeft);
    InputComponent->BindKey(EKeys::Right, IE_Pressed, this, &AMbgenPlayerController::NudgeRight);
    InputComponent->BindKey(EKeys::Up, IE_Pressed, this, &AMbgenPlayerController::NudgeUp);
    InputComponent->BindKey(EKeys::Down, IE_Pressed, this, &AMbgenPlayerController::NudgeDown);
    InputComponent->BindKey(EKeys::Z, IE_Pressed, this, &AMbgenPlayerController::ChordUndo);
    InputComponent->BindKey(EKeys::Y, IE_Pressed, this, &AMbgenPlayerController::ChordRedo);
    InputComponent->BindKey(EKeys::S, IE_Pressed, this, &AMbgenPlayerController::ChordSave);
    InputComponent->BindKey(EKeys::O, IE_Pressed, this, &AMbgenPlayerController::ChordOpen);
    InputComponent->BindKey(EKeys::V, IE_Pressed, this, &AMbgenPlayerController::ChordPaste);
}

void AMbgenPlayerController::OrbitPressed()
{
    bOrbit = true;
    bOrbitMoved = false;
    OrbitDownPos = FSlateApplication::Get().GetCursorPos();
    FVector Origin, Dir, Hit;
    AMbgenOrbitPawn* Orbit = Cast<AMbgenOrbitPawn>(GetPawn());
    if (!Orbit) { return; }
    if (DeprojectMousePositionToWorld(Origin, Dir))
    {
        FHitResult Trace;
        if (GetHitResultUnderCursor(ECC_Visibility, false, Trace))
        {
            if (UPrimitiveComponent* Prim = Trace.GetComponent(); Prim && Prim->ComponentTags.Num() > 0)
            {
                const FString Id = Prim->ComponentTags[0].ToString();
                if (AMbgenBoardActor* B = Board(); B && AMbgenBoardActor::IsEditablePart(Id)) { B->SelectPart(Id); }
            }
            Orbit->OrbitAbout(Trace.ImpactPoint);
        }
        else if (AMbgenBoardActor* B = Board(); B && B->HitDeskWorld(Origin, Dir, Hit))
        {
            Orbit->OrbitAbout(Hit);
        }
    }
}
void AMbgenPlayerController::OrbitReleased()
{
    bOrbit = false;
    if (!bOrbitMoved)
    {
        if (AMbgenBoardActor* B = Board()) { B->TurnSelected(); }
    }
}
void AMbgenPlayerController::PanPressed() { bPan = true; }
void AMbgenPlayerController::PanReleased() { bPan = false; }
void AMbgenPlayerController::ZoomToward(float Notches)
{
    AMbgenOrbitPawn* Orbit = Cast<AMbgenOrbitPawn>(GetPawn());
    if (!Orbit) { return; }
    FVector Origin, Dir, Hit;
    if (DeprojectMousePositionToWorld(Origin, Dir))
    {
        FHitResult Trace;
        if (GetHitResultUnderCursor(ECC_Visibility, false, Trace))
        {
            Orbit->AddZoomToward(Trace.ImpactPoint, Notches);
            return;
        }
        if (AMbgenBoardActor* B = Board(); B && B->HitDeskWorld(Origin, Dir, Hit))
        {
            Orbit->AddZoomToward(Hit, Notches);
            return;
        }
    }
    Orbit->AddZoom(FMbgenStore::ClampWheel(Notches));
}
void AMbgenPlayerController::ZoomIn() { ZoomToward(1.f); }
void AMbgenPlayerController::ZoomOut() { ZoomToward(-1.f); }
void AMbgenPlayerController::FramePressed()
{
    if (AMbgenBoardActor* B = Board()) { B->FrameOrbit(); }
}

void AMbgenPlayerController::CompilePressed()
{
    AMbgenBoardActor* B = Board();
    if (!B) { return; }
    B->CompileBoard();
    if (PropertyWindow && PropertyWindow->IsInViewport()) { PropertyWindow->ShowPart(B->SelectedId); }
}
void AMbgenPlayerController::PlaceReleased()
{
    const bool bWasPlace = bPlaceDrag;
    bLookDrag = false;
    bPlaceDrag = false;
    FString RoleId;
    if (UMbgenLibraryWidget::TakeRoleDrop(RoleId))
    {
        FVector Origin, Dir;
        if (DeprojectMousePositionToWorld(Origin, Dir))
        {
            if (AMbgenBoardActor* B = Board()) { B->DropRoleAtRay(RoleId, Origin, Dir); }
        }
        return;
    }
    if (bWasPlace)
    {
        if (AMbgenBoardActor* B = Board()) { B->FinishPlaceDrag(); }
    }
}
void AMbgenPlayerController::DeletePressed() { if (AMbgenBoardActor* B = Board()) { B->DeleteSelected(); } }
void AMbgenPlayerController::NudgeLeft() { Nudge(-1.f, 0.f, false); }
void AMbgenPlayerController::NudgeRight() { Nudge(1.f, 0.f, false); }
void AMbgenPlayerController::NudgeUp() { Nudge(0.f, 1.f, false); }
void AMbgenPlayerController::NudgeDown() { Nudge(0.f, -1.f, false); }

void AMbgenPlayerController::Tick(float DeltaSeconds)
{
    Super::Tick(DeltaSeconds);
    UMbgenLibraryWidget::NoteRoleDragMove(FSlateApplication::Get().GetCursorPos());
    float DX = 0.f, DY = 0.f;
    GetInputMouseDelta(DX, DY);
    AMbgenOrbitPawn* Orbit = Cast<AMbgenOrbitPawn>(GetPawn());
    const bool bAlt = IsInputKeyDown(EKeys::LeftAlt) || IsInputKeyDown(EKeys::RightAlt);
    const bool bCtrl = IsInputKeyDown(EKeys::LeftControl) || IsInputKeyDown(EKeys::RightControl);
    const bool bLeft = IsInputKeyDown(EKeys::LeftMouseButton);
    if (Orbit && !(FMath::IsNearlyZero(DX) && FMath::IsNearlyZero(DY)))
    {
        if (bOrbit && (FSlateApplication::Get().GetCursorPos() - OrbitDownPos).Size() > 8.f) { bOrbitMoved = true; }
        if (bLookDrag && bLeft && !bAlt && !bOrbit && !bPan && !bCtrl) { Orbit->AddLook(DX * 0.12f, -DY * 0.10f); }
        else if (bPan && bOrbit) { Orbit->AddOrbit(DX * 0.12f, -DY * 0.10f); }
        else if (bAlt && bLeft) { Orbit->AddOrbit(DX * 0.12f, -DY * 0.10f); }
        else if (bPan) { Orbit->AddPan(DX, -DY); }
        else if (bOrbit) { Orbit->AddOrbit(DX * 0.12f, -DY * 0.10f); }
    }
    if (bPlaceDrag && bLeft && !bAlt && !bOrbit && !bPan && !bCtrl && !(FMath::IsNearlyZero(DX) && FMath::IsNearlyZero(DY)) && !UMbgenLibraryWidget::IsRoleDrag())
    {
        FVector Origin, Dir;
        if (DeprojectMousePositionToWorld(Origin, Dir))
        {
            if (AMbgenBoardActor* B = Board()) { B->PlaceSelectedAtRay(Origin, Dir); }
        }
    }
    if (ChromeBar && ChromeBar->IsInViewport() && GEngine && GEngine->GameViewport)
    {
        FVector2D Size(1280.f, 720.f);
        GEngine->GameViewport->GetViewportSize(Size);
        const FVector2D Desired = ChromeBar->GetDesiredSize();
        const float W = Desired.X > 8.f ? Desired.X : 430.f;
        ChromeBar->SetPositionInViewport(FVector2D(FMath::Max(8.f, Size.X - W - 8.f), 8.f), false);
    }
    if (AMbgenBoardActor* B = Board())
    {
        FVector CamLoc;
        FRotator CamRot;
        GetPlayerViewPoint(CamLoc, CamRot);
        B->UpdateBottomView(CamLoc);
    }
}

AMbgenBoardActor* AMbgenPlayerController::Board() const
{
    return AMbgenBoardActor::FindLive(GetWorld());
}

void AMbgenPlayerController::SelectUnderCursor()
{
    bLookDrag = false;
    bPlaceDrag = false;
    FHitResult Hit;
    if (!GetHitResultUnderCursor(ECC_Visibility, false, Hit))
    {
        bLookDrag = true;
        return;
    }
    if (UPrimitiveComponent* Prim = Hit.GetComponent())
    {
        if (AMbgenBoardActor* B = Board())
        {
            if (Prim->ComponentTags.Num() > 0)
            {
                const FString Id = Prim->ComponentTags[0].ToString();
                if (AMbgenBoardActor::IsEditablePart(Id))
                {
                    B->SelectedId = Id;
                    bPlaceDrag = true;
                    UE_LOG(LogTemp, Display, TEXT("mbgen selected %s"), *B->SelectedId);
                    B->PaintAnchors();
                    ShowProperties(B->SelectedId);
                    if (B->PortRole(B->SelectedId) == TEXT("socket")) { ShowPackages(); }
                }
                else
                {
                    bLookDrag = true;
                }
            }
            else
            {
                bLookDrag = true;
            }
        }
    }
    const bool bCtrl = IsInputKeyDown(EKeys::LeftControl) || IsInputKeyDown(EKeys::RightControl);
    if (bCtrl)
    {
        if (AMbgenBoardActor* B = Board(); B && !B->SelectedId.IsEmpty())
        {
            B->CopySelected();
        }
    }
}

void AMbgenPlayerController::Nudge(float AlongX, float AlongY, bool Fine)
{
    AMbgenBoardActor* B = Board();
    if (!B || B->SelectedId.IsEmpty()) { return; }
    const bool bFine = Fine || IsInputKeyDown(EKeys::LeftShift) || IsInputKeyDown(EKeys::RightShift);
    B->NudgeSelectedOnPlane(FMath::RoundToInt(AlongX), FMath::RoundToInt(AlongY), bFine);
}

void AMbgenPlayerController::ShowPackages()
{
    if (PackageWindow && PackageWindow->IsInViewport()) { return; }
    PackageWindow = CreateWidget<UMbgenPackageWidget>(this, UMbgenPackageWidget::StaticClass());
    if (PackageWindow)
    {
        PackageWindow->AddToViewport(10);
        PackageWindow->SetPositionInViewport(FVector2D(24.f, 24.f), false);
        UE_LOG(LogTemp, Display, TEXT("mbgen package window open"));
    }
}

void AMbgenPlayerController::ChordUndo()
{
    if (IsInputKeyDown(EKeys::LeftControl) || IsInputKeyDown(EKeys::RightControl)) { FMbgenChrome::Undo(); }
}
void AMbgenPlayerController::ChordRedo()
{
    if (IsInputKeyDown(EKeys::LeftControl) || IsInputKeyDown(EKeys::RightControl)) { FMbgenChrome::Redo(); }
}
void AMbgenPlayerController::ChordSave()
{
    if (IsInputKeyDown(EKeys::LeftControl) || IsInputKeyDown(EKeys::RightControl)) { FMbgenChrome::Save(); }
}
void AMbgenPlayerController::ChordOpen()
{
    if (IsInputKeyDown(EKeys::LeftControl) || IsInputKeyDown(EKeys::RightControl)) { FMbgenChrome::Open(); }
}
void AMbgenPlayerController::ChordCopy()
{
    FMbgenChrome::Copy();
}
void AMbgenPlayerController::ChordPaste()
{
    if (IsInputKeyDown(EKeys::LeftControl) || IsInputKeyDown(EKeys::RightControl)) { FMbgenChrome::Paste(); }
}

void AMbgenPlayerController::TogglePackages()
{
    if (IsInputKeyDown(EKeys::LeftControl) || IsInputKeyDown(EKeys::RightControl))
    {
        FMbgenChrome::Copy();
        return;
    }
    if (PackageWindow && PackageWindow->IsInViewport())
    {
        PackageWindow->RemoveFromParent();
        return;
    }
    ShowPackages();
}

void AMbgenPlayerController::ToggleLibrary()
{
    if (LibraryWindow && LibraryWindow->IsInViewport())
    {
        LibraryWindow->RemoveFromParent();
        return;
    }
    LibraryWindow = CreateWidget<UMbgenLibraryWidget>(this, UMbgenLibraryWidget::StaticClass());
    if (LibraryWindow)
    {
        LibraryWindow->AddToViewport(10);
        LibraryWindow->SetPositionInViewport(FVector2D(24.f, 24.f), false);
        UE_LOG(LogTemp, Display, TEXT("mbgen library window open"));
    }
}

void AMbgenPlayerController::ToggleOutline()
{
    if (OutlineWindow && OutlineWindow->IsInViewport())
    {
        OutlineWindow->RemoveFromParent();
        return;
    }
    OutlineWindow = CreateWidget<UMbgenOutlineWidget>(this, UMbgenOutlineWidget::StaticClass());
    if (OutlineWindow)
    {
        OutlineWindow->AddToViewport(10);
        OutlineWindow->SetPositionInViewport(FVector2D(24.f, 24.f), false);
        UE_LOG(LogTemp, Display, TEXT("mbgen outline window open"));
    }
}

void AMbgenPlayerController::ShowProperties(const FString& Id)
{
    if (!(PropertyWindow && PropertyWindow->IsInViewport()))
    {
        PropertyWindow = CreateWidget<UMbgenPropertyWidget>(this, UMbgenPropertyWidget::StaticClass());
        if (PropertyWindow)
        {
            PropertyWindow->AddToViewport(11);
            PropertyWindow->SetPositionInViewport(FVector2D(24.f, 360.f), false);
            UE_LOG(LogTemp, Display, TEXT("mbgen property window open"));
        }
    }
    if (PropertyWindow) { PropertyWindow->ShowPart(Id); }
}

void AMbgenPlayerController::ToggleProperties()
{
    if (PropertyWindow && PropertyWindow->IsInViewport())
    {
        PropertyWindow->RemoveFromParent();
        return;
    }
    ShowProperties(Board() ? Board()->SelectedId : FString());
}

void AMbgenPlayerController::ToggleBottom()
{
    if (AMbgenBoardActor* B = Board()) { B->ToggleBottomView(); }
}
