#include "MbgenEditorBridge.h"

#if WITH_EDITOR

#include "MbgenBoardActor.h"
#include "MbgenNav.h"
#include "MbgenPackageWidget.h"
#include "MbgenLibraryWidget.h"
#include "MbgenOutlineWidget.h"
#include "MbgenIssuesWidget.h"
#include "MbgenPropertyWidget.h"
#include "MbgenSettings.h"
#include "MbgenStore.h"
#include "MbgenChrome.h"
#include "Editor.h"
#include "LevelEditor.h"
#include "SLevelViewport.h"
#include "LevelEditorViewport.h"
#include "EngineUtils.h"
#include "Engine/World.h"
#include "CollisionQueryParams.h"
#include "Framework/Application/SlateApplication.h"
#include "Framework/Application/IInputProcessor.h"
#include "Widgets/SWindow.h"
#include "DrawDebugHelpers.h"
#include "Misc/FileHelper.h"
#include "Misc/Paths.h"

class FMbgenEditorInput : public IInputProcessor
{
public:
    virtual void Tick(const float, FSlateApplication&, TSharedRef<ICursor>) override { FMbgenChrome::Tick(); }
    virtual bool HandleKeyDownEvent(FSlateApplication& SlateApp, const FKeyEvent& Event) override;
    virtual bool HandleMouseButtonDownEvent(FSlateApplication& SlateApp, const FPointerEvent& Event) override;
    virtual bool HandleMouseButtonUpEvent(FSlateApplication& SlateApp, const FPointerEvent& Event) override;
    virtual bool HandleMouseMoveEvent(FSlateApplication& SlateApp, const FPointerEvent& Event) override;
    virtual bool HandleMouseWheelOrGestureEvent(FSlateApplication& SlateApp, const FPointerEvent& Event, const FPointerEvent* GestureEvent) override;
    bool bMiddleDown = false;
    bool bRightDown = false;
    bool bLeftDown = false;
    bool bRightMoved = false;
    bool bLookDrag = false;
    bool bPlaceDrag = false;
    FVector2D RightDownPos = FVector2D::ZeroVector;
    virtual const TCHAR* GetDebugName() const override { return TEXT("MbgenEditorInput"); }
};

static TSharedPtr<FMbgenEditorInput> GInput;
static FVector GNavPivot(0.f, 0.f, 0.f);
static FString GRightPartId;
/* The viewport a gesture started in. Every sample of that gesture (move,
   release, cancel) is resolved against it, so a second viewport or a
   focus change mid-drag cannot redirect the part or the camera. */
static TWeakPtr<SLevelViewport> GGestureViewport;
static TWeakPtr<SWindow> GPackageWindow;
static TWeakPtr<SWindow> GLibraryWindow;
static TWeakPtr<SWindow> GOutlineWindow;
static TWeakPtr<SWindow> GIssuesWindow;
static TWeakPtr<SWindow> GPropertyWindow;
static TWeakObjectPtr<UMbgenPropertyWidget> GPropertyWidget;

static bool InPie()
{
    return GEditor && GEditor->PlayWorld != nullptr;
}

static TSharedPtr<SLevelViewport> LevelViewportInPath(const FWidgetPath* Path)
{
    if (!Path) { return nullptr; }
    for (int32 Index = 0; Index < Path->Widgets.Num(); ++Index)
    {
        const TSharedRef<SWidget>& Widget = Path->Widgets[Index].Widget;
        if (Widget->GetTypeAsString().Contains(TEXT("SLevelViewport")))
        {
            return StaticCastSharedRef<SLevelViewport>(Widget);
        }
    }
    return nullptr;
}

static bool PathHasLevelViewport(const FWidgetPath* Path)
{
    return LevelViewportInPath(Path).IsValid();
}

static bool FocusIsLevelViewport()
{
    TSharedPtr<SWidget> Widget = FSlateApplication::Get().GetKeyboardFocusedWidget();
    while (Widget.IsValid())
    {
        if (Widget->GetTypeAsString().Contains(TEXT("SLevelViewport"))) { return true; }
        Widget = Widget->GetParentWidget();
    }
    return false;
}

static AMbgenBoardActor* FindBoard()
{
    return AMbgenBoardActor::FindLive(nullptr);
}

static TSharedPtr<SLevelViewport> ActiveLevelViewport()
{
    if (!FModuleManager::Get().IsModuleLoaded("LevelEditor")) { return nullptr; }
    FLevelEditorModule& Module = FModuleManager::GetModuleChecked<FLevelEditorModule>("LevelEditor");
    return Module.GetFirstActiveLevelViewport();
}

/* The initiating viewport while a gesture is live, else the active one. */
static TSharedPtr<SLevelViewport> GestureViewport()
{
    if (TSharedPtr<SLevelViewport> Captured = GGestureViewport.Pin()) { return Captured; }
    return ActiveLevelViewport();
}

static bool TraceViewport(FHitResult& Hit)
{
    TSharedPtr<SLevelViewport> Viewport = GestureViewport();
    if (!Viewport.IsValid()) { return false; }
    FLevelEditorViewportClient& Client = Viewport->GetLevelViewportClient();
    UWorld* World = Client.GetWorld();
    if (!World) { return false; }
    const FViewportCursorLocation Cursor = Client.GetCursorWorldLocationFromMousePos();
    const FVector Start = Cursor.GetOrigin();
    const FVector End = Start + Cursor.GetDirection() * 100000.f;
    return World->LineTraceSingleByChannel(Hit, Start, End, ECC_Visibility, FCollisionQueryParams(SCENE_QUERY_STAT(MbgenPick), false));
}

static void OpenPackageWindow()
{
    if (GPackageWindow.IsValid() || !GEditor) { return; }
    UWorld* World = GEditor->GetEditorWorldContext().World();
    if (!World) { return; }
    UMbgenPackageWidget* Widget = CreateWidget<UMbgenPackageWidget>(World, UMbgenPackageWidget::StaticClass());
    if (!Widget) { return; }
    TSharedRef<SWindow> Window = SNew(SWindow)
        .Title(FText::FromString(TEXT("Processor")))
        .ClientSize(FVector2D(560.f, 720.f))
        .SupportsMaximize(false);
    Window->SetContent(Widget->TakeWidget());
    GPackageWindow = Window;
    FSlateApplication::Get().AddWindow(Window);
    UE_LOG(LogTemp, Display, TEXT("mbgen package window open"));
}

static void TogglePackageWindow()
{
    if (TSharedPtr<SWindow> Existing = GPackageWindow.Pin())
    {
        Existing->RequestDestroyWindow();
        GPackageWindow.Reset();
        return;
    }
    OpenPackageWindow();
}

static void OpenLibraryWindow()
{
    if (GLibraryWindow.IsValid() || !GEditor) { return; }
    UWorld* World = GEditor->GetEditorWorldContext().World();
    if (!World) { return; }
    UMbgenLibraryWidget* Widget = CreateWidget<UMbgenLibraryWidget>(World, UMbgenLibraryWidget::StaticClass());
    if (!Widget) { return; }
    TSharedRef<SWindow> Window = SNew(SWindow)
        .Title(FText::FromString(TEXT("Parts")))
        .ClientSize(FVector2D(520.f, 720.f))
        .SupportsMaximize(false);
    Window->SetContent(Widget->TakeWidget());
    GLibraryWindow = Window;
    FSlateApplication::Get().AddWindow(Window);
    UE_LOG(LogTemp, Display, TEXT("mbgen library window open"));
}

static void ToggleLibraryWindow()
{
    if (TSharedPtr<SWindow> Existing = GLibraryWindow.Pin())
    {
        Existing->RequestDestroyWindow();
        GLibraryWindow.Reset();
        return;
    }
    OpenLibraryWindow();
}

static void OpenOutlineWindow()
{
    if (GOutlineWindow.IsValid() || !GEditor) { return; }
    UWorld* World = GEditor->GetEditorWorldContext().World();
    if (!World) { return; }
    UMbgenOutlineWidget* Widget = CreateWidget<UMbgenOutlineWidget>(World, UMbgenOutlineWidget::StaticClass());
    if (!Widget) { return; }
    TSharedRef<SWindow> Window = SNew(SWindow)
        .Title(FText::FromString(TEXT("Board")))
        .ClientSize(FVector2D(420.f, 360.f))
        .SupportsMaximize(false);
    Window->SetContent(Widget->TakeWidget());
    GOutlineWindow = Window;
    FSlateApplication::Get().AddWindow(Window);
    UE_LOG(LogTemp, Display, TEXT("mbgen outline window open"));
}

static void ToggleOutlineWindow()
{
    if (TSharedPtr<SWindow> Existing = GOutlineWindow.Pin())
    {
        Existing->RequestDestroyWindow();
        GOutlineWindow.Reset();
        return;
    }
    OpenOutlineWindow();
}

static void OpenIssuesWindow()
{
    if (GIssuesWindow.IsValid() || !GEditor) { return; }
    UWorld* World = GEditor->GetEditorWorldContext().World();
    if (!World) { return; }
    UMbgenIssuesWidget* Widget = CreateWidget<UMbgenIssuesWidget>(World, UMbgenIssuesWidget::StaticClass());
    if (!Widget) { return; }
    TSharedRef<SWindow> Window = SNew(SWindow)
        .Title(FText::FromString(TEXT("Issues")))
        .ClientSize(FVector2D(560.f, 480.f))
        .SupportsMaximize(false);
    Window->SetContent(Widget->TakeWidget());
    GIssuesWindow = Window;
    FSlateApplication::Get().AddWindow(Window);
    UE_LOG(LogTemp, Display, TEXT("mbgen issues window open"));
}

static void ToggleIssuesWindow()
{
    if (TSharedPtr<SWindow> Existing = GIssuesWindow.Pin())
    {
        Existing->RequestDestroyWindow();
        GIssuesWindow.Reset();
        return;
    }
    OpenIssuesWindow();
}

static void OpenPropertyWindow(const FString& Id)
{
    if (!GEditor) { return; }
    if (TSharedPtr<SWindow> Existing = GPropertyWindow.Pin())
    {
        if (GPropertyWidget.IsValid()) { GPropertyWidget->ShowPart(Id); }
        Existing->BringToFront(true);
        return;
    }
    UWorld* World = GEditor->GetEditorWorldContext().World();
    if (!World) { return; }
    UMbgenPropertyWidget* Widget = CreateWidget<UMbgenPropertyWidget>(World, UMbgenPropertyWidget::StaticClass());
    if (!Widget) { return; }
    TSharedRef<SWindow> Window = SNew(SWindow)
        .Title(FText::FromString(TEXT("Properties")))
        .ClientSize(FVector2D(420.f, 480.f))
        .SupportsMaximize(false);
    GPropertyWidget = Widget;
    Window->SetContent(Widget->TakeWidget());
    Widget->ShowPart(Id);
    GPropertyWindow = Window;
    FSlateApplication::Get().AddWindow(Window);
    UE_LOG(LogTemp, Display, TEXT("mbgen property window open"));
}

static void TogglePropertyWindow()
{
    if (TSharedPtr<SWindow> Existing = GPropertyWindow.Pin())
    {
        Existing->RequestDestroyWindow();
        GPropertyWindow.Reset();
        GPropertyWidget.Reset();
        return;
    }
    AMbgenBoardActor* Board = FindBoard();
    OpenPropertyWindow(Board ? Board->SelectedId : FString());
}

static void NudgeSelected(AMbgenBoardActor* Board, int32 AlongX, int32 AlongY, bool bFine)
{
    if (!Board) { return; }
    Board->NudgeSelectedOnPlane(AlongX, AlongY, bFine);
}

static FString HitPartId(const FHitResult& Hit)
{
    UPrimitiveComponent* Prim = Hit.GetComponent();
    if (!Prim || Prim->ComponentTags.Num() == 0) { return FString(); }
    const FString Id = Prim->ComponentTags[0].ToString();
    return AMbgenBoardActor::IsEditablePart(Id) ? Id : FString();
}

static bool HitIsEditablePart(const FHitResult& Hit)
{
    return !HitPartId(Hit).IsEmpty();
}

static FRotator LevelLook(FRotator Rot)
{
    Rot.Roll = 0.f;
    Rot.Pitch = FMath::Clamp(Rot.Pitch, -85.f, 85.f);
    return Rot;
}

static void PinView(FLevelEditorViewportClient* Client, const FVector& Cam, const FRotator& Rot, const FVector& LookAt)
{
    Client->ToggleOrbitCamera(false);
    Client->SetViewRotation(Rot);
    Client->SetViewLocation(Cam);
    Client->SetLookAtLocation(LookAt, false);
}

static void LookViewport(FLevelEditorViewportClient* Client, const FVector2D& Delta)
{
    // Camera stays put; the shared law yaws about world Z and pitches about
    // the post-yaw camera right (mbcore nav::look_in_place).
    const FVector Cam = Client->GetViewLocation();
    const float S = FMbgenStore::MouseSens();
    const FVector Forward = FMbgenNav::Look(Client->GetViewRotation().Vector(), Delta.X * 0.12 * S, -Delta.Y * 0.10 * S);
    const FRotator Next = FMbgenNav::LevelLook(Forward);
    PinView(Client, Cam, Next, GNavPivot);
    Client->Invalidate();
    if (AMbgenBoardActor* Board = FindBoard()) { Board->UpdateBottomView(Cam); }
}

static FVector PickNavPivot(FLevelEditorViewportClient* Client)
{
    AMbgenBoardActor* Board = FindBoard();
    FHitResult Hit;
    if (TraceViewport(Hit) && Board && Hit.GetActor() == Board && HitIsEditablePart(Hit))
    {
        return Hit.ImpactPoint;
    }
    if (Client && Board)
    {
        // Shared law: desk hit inside the pad, else on the cursor ray at the
        // last focus depth. Never a clamped rim corner (progress.md leftover).
        const FViewportCursorLocation Cursor = Client->GetCursorWorldLocationFromMousePos();
        return Board->NavPickPivotWorld(Cursor.GetOrigin(), Cursor.GetDirection(), GNavPivot);
    }
    return GNavPivot;
}

static FLevelEditorViewportClient* PerspectiveClient()
{
    if (!GEditor) { return nullptr; }
    for (FLevelEditorViewportClient* Client : GEditor->GetLevelViewportClients())
    {
        if (Client && Client->IsPerspective() && Client->Viewport && Client->Viewport->GetSizeXY().X >= 64)
        {
            return Client;
        }
    }
    return nullptr;
}

/* Camera client for the live gesture: the initiating viewport's when it is
   perspective, else the first perspective client. */
static FLevelEditorViewportClient* GestureClient()
{
    if (TSharedPtr<SLevelViewport> Captured = GGestureViewport.Pin())
    {
        FLevelEditorViewportClient& Client = Captured->GetLevelViewportClient();
        if (Client.IsPerspective() && Client.Viewport) { return &Client; }
    }
    return PerspectiveClient();
}

void FMbgenEditorBridge::DiagnoseNav()
{
    FLevelEditorViewportClient* Client = PerspectiveClient();
    AMbgenBoardActor* Board = FindBoard();
    if (!Client || !Board) { return; }
    const FVector Cam = Client->GetViewLocation();
    const FRotator Rot = Client->GetViewRotation();
    const FVector LookAt = Client->GetLookAtLocation();
    const float Fov = Client->ViewFOV;
    const int32 Orbit = Client->ShouldOrbitCamera() ? 1 : 0;
    FVector DeskHit = GNavPivot;
    Board->HitDeskWorld(Cam, Rot.Vector(), DeskHit);
    FVector CursorDesk = DeskHit;
    const FViewportCursorLocation Cursor = Client->GetCursorWorldLocationFromMousePos();
    Board->HitDeskWorld(Cursor.GetOrigin(), Cursor.GetDirection(), CursorDesk);
    FVector Pcb(0.f);
    {
        FVector Corners[4];
        if (Board->DeskCornersWorld(Corners))
        {
            Pcb = (Corners[0] + Corners[2]) * 0.5f;
        }
    }
    const float DPcb = FVector::Dist(Cam, Pcb);
    const float DLook = FVector::Dist(Cam, LookAt);
    const float DDesk = FVector::Dist(Cam, DeskHit);
    const float DPivot = FVector::Dist(Cam, GNavPivot);
    const float Recede = (DLook > DDesk * 1.25f && DLook > DPcb * 1.25f) ? 1.f : 0.f;
    UE_LOG(LogTemp, Display,
        TEXT("mbgen navdiag cam=%.1f %.1f %.1f look=%.1f %.1f %.1f fov=%.1f orbit=%d pivot=%.1f %.1f %.1f desk=%.1f %.1f %.1f cursor=%.1f %.1f %.1f pcb=%.1f %.1f %.1f d_pcb=%.1f d_look=%.1f d_desk=%.1f d_pivot=%.1f recede=%d"),
        Cam.X, Cam.Y, Cam.Z, LookAt.X, LookAt.Y, LookAt.Z, Fov, Orbit,
        GNavPivot.X, GNavPivot.Y, GNavPivot.Z, DeskHit.X, DeskHit.Y, DeskHit.Z,
        CursorDesk.X, CursorDesk.Y, CursorDesk.Z, Pcb.X, Pcb.Y, Pcb.Z,
        DPcb, DLook, DDesk, DPivot, Recede > 0.f ? 1 : 0);
    LookViewport(Client, FVector2D(240.f, -180.f));
    const FVector LookCam = Client->GetViewLocation();
    const float LookMoved = FVector::Dist(Cam, LookCam);
    const float LookD1 = FVector::Dist(LookCam, Pcb);
    PinView(Client, Cam, Rot, LookAt);
    FVector Offset = Cam - GNavPivot;
    const float OrbitDist0 = FMath::Max(Offset.Size(), 1.f);
    FRotator OrbitRot = Offset.Rotation();
    OrbitRot.Yaw += 24.f;
    OrbitRot.Pitch = FMath::Clamp(OrbitRot.Pitch + 12.f, -85.f, 85.f);
    OrbitRot.Roll = 0.f;
    const FVector OrbitCam = GNavPivot + OrbitRot.Vector() * OrbitDist0;
    const float OrbitD1 = FVector::Dist(OrbitCam, Pcb);
    const float OrbitMoved = FVector::Dist(Cam, OrbitCam);
    UE_LOG(LogTemp, Display,
        TEXT("mbgen navdiag sweep look_moved=%.2f look_d0=%.1f look_d1=%.1f orbit_moved=%.1f orbit_d0=%.1f orbit_d1=%.1f fov=%.1f cursor_rim=%d"),
        LookMoved, DPcb, LookD1, OrbitMoved, DPcb, OrbitD1, Fov,
        (FVector::Dist(CursorDesk, Pcb) > 80.f) ? 1 : 0);
    UWorld* World = Client->GetWorld();
    if (World)
    {
        FVector Corners[4];
        if (Board->DeskCornersWorld(Corners))
        {
            for (int32 i = 0; i < 4; ++i)
            {
                DrawDebugLine(World, Corners[i], Corners[(i + 1) & 3], FColor(0, 220, 220), false, 12.f, 0, 2.f);
            }
        }
        DrawDebugLine(World, Cam, DeskHit, FColor(240, 220, 40), false, 12.f, 0, 1.5f);
        DrawDebugLine(World, Cam, LookAt, FColor(220, 40, 40), false, 12.f, 0, 1.2f);
        DrawDebugSphere(World, DeskHit, 3.f, 8, FColor(240, 220, 40), false, 12.f);
        DrawDebugSphere(World, LookAt, 3.f, 8, FColor(220, 40, 40), false, 12.f);
        DrawDebugSphere(World, GNavPivot, 4.f, 8, FColor(80, 180, 255), false, 12.f);
    }
    const FString Json = FString::Printf(
        TEXT("{\"cam\":[%.3f,%.3f,%.3f],\"rot\":[%.3f,%.3f,%.3f],\"look\":[%.3f,%.3f,%.3f],\"fov\":%.3f,\"orbit\":%d,\"pivot\":[%.3f,%.3f,%.3f],\"desk\":[%.3f,%.3f,%.3f],\"cursor_desk\":[%.3f,%.3f,%.3f],\"pcb\":[%.3f,%.3f,%.3f],\"d_pcb\":%.3f,\"d_look\":%.3f,\"d_desk\":%.3f,\"d_pivot\":%.3f,\"recede\":%d,\"look_moved\":%.3f,\"look_d1\":%.3f,\"orbit_moved\":%.3f,\"orbit_d1\":%.3f}"),
        Cam.X, Cam.Y, Cam.Z, Rot.Pitch, Rot.Yaw, Rot.Roll,
        LookAt.X, LookAt.Y, LookAt.Z, Fov, Orbit,
        GNavPivot.X, GNavPivot.Y, GNavPivot.Z, DeskHit.X, DeskHit.Y, DeskHit.Z,
        CursorDesk.X, CursorDesk.Y, CursorDesk.Z, Pcb.X, Pcb.Y, Pcb.Z,
        DPcb, DLook, DDesk, DPivot, Recede > 0.f ? 1 : 0,
        LookMoved, LookD1, OrbitMoved, OrbitD1);
    FFileHelper::SaveStringToFile(Json, *(FPaths::ProjectSavedDir() / TEXT("mbgen-navdiag.json")));
    Client->Invalidate();
    if (GEditor) { GEditor->RedrawLevelEditingViewports(); }
}

void FMbgenEditorBridge::FrameOrbit(const FVector& WorldPivot)
{
    GNavPivot = WorldPivot;
    FLevelEditorViewportClient* Client = PerspectiveClient();
    if (!Client) { return; }
    const FVector Loc = Client->GetViewLocation();
    float Dist = (Loc - GNavPivot).Size();
    if (Dist < 12.f) { Dist = 400.f; }
    const FVector NewLoc = GNavPivot + (Loc - GNavPivot).GetSafeNormal() * Dist;
    const FRotator Look = LevelLook((GNavPivot - NewLoc).Rotation());
    PinView(Client, NewLoc, Look, GNavPivot);
    Client->Invalidate();
}

static void DollyViewport(FLevelEditorViewportClient* Client, float Notches)
{
    const FVector Hit = PickNavPivot(Client);
    const FVector Loc = Client->GetViewLocation();
    FRotator Keep = Client->GetViewRotation();
    Keep.Roll = 0.f;
    const FVector NewLoc = FMbgenNav::ZoomToward(Loc, Hit, Notches, FMbgenStore::MouseSens());
    GNavPivot = Hit;
    PinView(Client, NewLoc, Keep, Hit);
    Client->Invalidate();
    if (AMbgenBoardActor* Board = FindBoard()) { Board->UpdateBottomView(NewLoc); }
}

bool FMbgenEditorInput::HandleMouseWheelOrGestureEvent(FSlateApplication&, const FPointerEvent& Event, const FPointerEvent*)
{
    if (InPie() || !PathHasLevelViewport(Event.GetEventPath())) { return false; }
    const float Wheel = Event.GetWheelDelta();
    if (FMath::IsNearlyZero(Wheel)) { return false; }
    if (FLevelEditorViewportClient* Client = PerspectiveClient())
    {
        DollyViewport(Client, FMbgenStore::ClampWheel(Wheel));
        return true;
    }
    return false;
}

bool FMbgenEditorInput::HandleMouseButtonUpEvent(FSlateApplication&, const FPointerEvent& Event)
{
    if (Event.GetEffectingButton() == EKeys::MiddleMouseButton) { bMiddleDown = false; }
    if (Event.GetEffectingButton() == EKeys::RightMouseButton)
    {
        bRightDown = false;
        if (!InPie() && PathHasLevelViewport(Event.GetEventPath()) && !bRightMoved)
        {
            if (AMbgenBoardActor* Board = FindBoard())
            {
                if (!GRightPartId.IsEmpty()) { Board->SelectPart(GRightPartId); }
                Board->TurnSelected();
            }
            return true;
        }
    }
    if (Event.GetEffectingButton() == EKeys::LeftMouseButton)
    {
        const bool bWasPlace = bPlaceDrag;
        bLeftDown = false;
        bLookDrag = false;
        bPlaceDrag = false;
        FString RoleId;
        if (UMbgenLibraryWidget::TakeRoleDrop(RoleId))
        {
            if (AMbgenBoardActor* Board = FindBoard())
            {
                TSharedPtr<SLevelViewport> Viewport = GestureViewport();
                if (Viewport.IsValid())
                {
                    FLevelEditorViewportClient& Client = Viewport->GetLevelViewportClient();
                    const FViewportCursorLocation Cursor = Client.GetCursorWorldLocationFromMousePos();
                    Board->DropRoleAtRay(RoleId, Cursor.GetOrigin(), Cursor.GetDirection());
                }
            }
        }
        if (bWasPlace)
        {
            if (AMbgenBoardActor* Board = FindBoard())
            {
                // Flush the release sample past the 10 Hz gate, then rebuild once.
                TSharedPtr<SLevelViewport> Viewport = GestureViewport();
                if (Viewport.IsValid() && Board->IsPlaceDragActive())
                {
                    FLevelEditorViewportClient& Client = Viewport->GetLevelViewportClient();
                    const FViewportCursorLocation Cursor = Client.GetCursorWorldLocationFromMousePos();
                    Board->PlaceSelectedAtRay(Cursor.GetOrigin(), Cursor.GetDirection(), true);
                }
                Board->FinishPlaceDrag();
            }
        }
        if (!bRightDown && !bMiddleDown) { GGestureViewport.Reset(); }
    }
    if (!bLeftDown && !bRightDown && !bMiddleDown) { GGestureViewport.Reset(); }
    return false;
}

static void PlaceFromCursor(AMbgenBoardActor* Board)
{
    if (!Board) { return; }
    TSharedPtr<SLevelViewport> Viewport = GestureViewport();
    if (!Viewport.IsValid()) { return; }
    FLevelEditorViewportClient& Client = Viewport->GetLevelViewportClient();
    const FViewportCursorLocation Cursor = Client.GetCursorWorldLocationFromMousePos();
    Board->PlaceSelectedAtRay(Cursor.GetOrigin(), Cursor.GetDirection());
}

bool FMbgenEditorInput::HandleMouseMoveEvent(FSlateApplication&, const FPointerEvent& Event)
{
    UMbgenLibraryWidget::NoteRoleDragMove(Event.GetScreenSpacePosition());
    if (InPie() || !PathHasLevelViewport(Event.GetEventPath())) { return false; }
    const FVector2D Delta = Event.GetCursorDelta();
    if (Delta.IsNearlyZero()) { return false; }
    const bool bAlt = Event.IsAltDown();
    FLevelEditorViewportClient* Client = GestureClient();
    if (bLookDrag && bLeftDown && !bAlt && !bMiddleDown && !bRightDown && !UMbgenLibraryWidget::IsRoleDrag())
    {
        if (Client)
        {
            LookViewport(Client, Delta);
            return true;
        }
    }
    if (bPlaceDrag && bLeftDown && !bAlt && !bMiddleDown && !bRightDown && !Event.IsControlDown() && !UMbgenLibraryWidget::IsRoleDrag())
    {
        AMbgenBoardActor* Board = FindBoard();
        if (Board && Board->IsPlaceDragActive())
        {
            PlaceFromCursor(Board);
            if (Client) { Board->UpdateBottomView(Client->GetViewLocation()); }
        }
    }
    if (!Client) { return false; }
    if (bRightDown && (Event.GetScreenSpacePosition() - RightDownPos).Size() > 8.f) { bRightMoved = true; }
    const bool bOrbit = bRightDown || (bMiddleDown && bRightDown) || (Event.IsAltDown() && Event.IsMouseButtonDown(EKeys::LeftMouseButton));
    const FVector Loc = Client->GetViewLocation();
    if (bOrbit)
    {
        const float S = FMbgenStore::MouseSens();
        FVector Fwd;
        const FVector NewLoc = FMbgenNav::Orbit(GNavPivot, Loc, Delta.X * 0.12 * S, -Delta.Y * 0.10 * S, Fwd);
        const FRotator Look = FMbgenNav::LevelLook(Fwd);
        PinView(Client, NewLoc, Look, GNavPivot);
        Client->Invalidate();
        if (AMbgenBoardActor* Board = FindBoard()) { Board->UpdateBottomView(NewLoc); }
        return true;
    }
    if (bMiddleDown)
    {
        const FRotationMatrix Axes(Client->GetViewRotation());
        const float Step = FMath::Max((Loc - GNavPivot).Size(), 20.f) * 0.0011f * FMbgenStore::MouseSens();
        const FVector Move = Axes.GetUnitAxis(EAxis::Y) * -Delta.X * Step + Axes.GetUnitAxis(EAxis::Z) * Delta.Y * Step;
        GNavPivot += Move;
        Client->SetViewLocation(Loc + Move);
        Client->Invalidate();
        if (AMbgenBoardActor* Board = FindBoard()) { Board->UpdateBottomView(Loc + Move); }
        return true;
    }
    return false;
}

bool FMbgenEditorInput::HandleMouseButtonDownEvent(FSlateApplication&, const FPointerEvent& Event)
{
    // Capture the viewport the gesture starts in, once, for its whole life.
    if (!GGestureViewport.IsValid() && !InPie())
    {
        if (TSharedPtr<SLevelViewport> Started = LevelViewportInPath(Event.GetEventPath())) { GGestureViewport = Started; }
    }
    if (Event.GetEffectingButton() == EKeys::MiddleMouseButton) { bMiddleDown = true; }
    if (Event.GetEffectingButton() == EKeys::RightMouseButton)
    {
        bRightDown = true;
        bRightMoved = false;
        RightDownPos = Event.GetScreenSpacePosition();
        GRightPartId.Empty();
        if (!InPie() && PathHasLevelViewport(Event.GetEventPath()))
        {
            if (FLevelEditorViewportClient* Client = GestureClient())
            {
                GNavPivot = PickNavPivot(Client);
            }
            FHitResult Hit;
            if (TraceViewport(Hit)) { GRightPartId = HitPartId(Hit); }
        }
    }
    if (Event.GetEffectingButton() == EKeys::LeftMouseButton)
    {
        bLeftDown = true;
        bLookDrag = false;
        bPlaceDrag = false;
    }
    if (InPie() || Event.GetEffectingButton() != EKeys::LeftMouseButton) { return false; }
    if (Event.IsAltDown()) { return false; }
    if (!PathHasLevelViewport(Event.GetEventPath())) { return false; }
    FHitResult Hit;
    if (!TraceViewport(Hit) || !HitIsEditablePart(Hit))
    {
        bLookDrag = true;
        // DiagnoseNav is a CallInEditor command, not a side effect of a click:
        // its synthetic sweep mutates the camera and must never run on input.
        if (FLevelEditorViewportClient* Client = GestureClient())
        {
            GNavPivot = PickNavPivot(Client);
        }
        return true;
    }
    bPlaceDrag = true;
    UPrimitiveComponent* Prim = Hit.GetComponent();
    if (!Prim || Prim->ComponentTags.Num() == 0) { return false; }
    AMbgenBoardActor* Board = FindBoard();
    if (!Board) { return false; }
    Board->BeginPlaceDrag();
    Board->SelectedId = Prim->ComponentTags[0].ToString();
    UE_LOG(LogTemp, Display, TEXT("mbgen selected %s"), *Board->SelectedId);
    Board->PaintAnchors();
    GEditor->SelectNone(true, true, false);
    GEditor->SelectActor(Board, true, true, true);
    OpenPropertyWindow(Board->SelectedId);
    if (Board->PortRole(Board->SelectedId) == TEXT("socket")) { OpenPackageWindow(); }
    if (Event.IsControlDown())
    {
        Board->CopySelected();
        return true;
    }
    return false;
}

bool FMbgenEditorInput::HandleKeyDownEvent(FSlateApplication&, const FKeyEvent& Event)
{
    if (InPie()) { return false; }
    const FKey Key = Event.GetKey();
    if (Event.IsControlDown())
    {
        if (Key == EKeys::Z) { FMbgenChrome::Undo(); return true; }
        if (Key == EKeys::Y) { FMbgenChrome::Redo(); return true; }
        if (Key == EKeys::S) { FMbgenChrome::Save(); return true; }
        if (Key == EKeys::O) { FMbgenChrome::Open(); return true; }
        if (Key == EKeys::C) { FMbgenChrome::Copy(); return true; }
        if (Key == EKeys::V) { FMbgenChrome::Paste(); return true; }
    }
    if (Key == EKeys::Escape)
    {
        // Escape during a drag restores the mouse-down design; the drag is over.
        if (AMbgenBoardActor* Dragging = FindBoard())
        {
            if (Dragging->CancelPlaceDrag())
            {
                bPlaceDrag = false;
                bLookDrag = false;
                GGestureViewport.Reset();
                return true;
            }
        }
    }
    if (!FocusIsLevelViewport()) { return false; }
    AMbgenBoardActor* Board = FindBoard();
    if (!Board) { return false; }
    if (Key == EKeys::C) { TogglePackageWindow(); return true; }
    if (Key == EKeys::L) { ToggleLibraryWindow(); return true; }
    if (Key == EKeys::T) { ToggleOutlineWindow(); return true; }
    if (Key == EKeys::I) { ToggleIssuesWindow(); return true; }
    if (Key == EKeys::P) { TogglePropertyWindow(); return true; }
    if (Key == EKeys::B)
    {
        Board->ToggleBottomView();
        return true;
    }
    if (Key == EKeys::F)
    {
        Board->FrameOrbit();
        return true;
    }
    if (Key == EKeys::Enter)
    {
        Board->CompileBoard();
        if (GPropertyWidget.IsValid()) { GPropertyWidget->ShowPart(Board->SelectedId); }
        return true;
    }
    if (Key == EKeys::Delete)
    {
        Board->DeleteSelected();
        return true;
    }
    int32 AlongX = 0;
    int32 AlongY = 0;
    if (Key == EKeys::Left) { AlongX = -1; }
    else if (Key == EKeys::Right) { AlongX = 1; }
    else if (Key == EKeys::Up) { AlongY = 1; }
    else if (Key == EKeys::Down) { AlongY = -1; }
    else { return false; }
    if (Board->SelectedId.IsEmpty()) { return false; }
    NudgeSelected(Board, AlongX, AlongY, Event.IsShiftDown());
    return true;
}

void FMbgenEditorBridge::Start()
{
    auto Register = []()
    {
        if (GInput.IsValid() || !FSlateApplication::IsInitialized()) { return; }
        GInput = MakeShared<FMbgenEditorInput>();
        FSlateApplication::Get().RegisterInputPreProcessor(GInput, 0);
        FMbgenChrome::Start();
        UE_LOG(LogTemp, Display, TEXT("mbgen editor input ready"));
    };
    if (FSlateApplication::IsInitialized()) { Register(); }
    FCoreDelegates::GetOnPostEngineInit().AddLambda(Register);
}

void FMbgenEditorBridge::Stop()
{
    if (GInput.IsValid() && FSlateApplication::IsInitialized())
    {
        FSlateApplication::Get().UnregisterInputPreProcessor(GInput);
    }
    GInput.Reset();
    FMbgenChrome::Stop();
    if (TSharedPtr<SWindow> Existing = GPackageWindow.Pin()) { Existing->RequestDestroyWindow(); }
    GPackageWindow.Reset();
    if (TSharedPtr<SWindow> Library = GLibraryWindow.Pin()) { Library->RequestDestroyWindow(); }
    GLibraryWindow.Reset();
    if (TSharedPtr<SWindow> Outline = GOutlineWindow.Pin()) { Outline->RequestDestroyWindow(); }
    GOutlineWindow.Reset();
    if (TSharedPtr<SWindow> Issues = GIssuesWindow.Pin()) { Issues->RequestDestroyWindow(); }
    GIssuesWindow.Reset();
    if (TSharedPtr<SWindow> Props = GPropertyWindow.Pin()) { Props->RequestDestroyWindow(); }
    GPropertyWindow.Reset();
    GPropertyWidget.Reset();
}

#else

void FMbgenEditorBridge::Start() {}
void FMbgenEditorBridge::Stop() {}

#endif
