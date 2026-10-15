#include "MbgenBoardActor.h"
#include "MbgenSettings.h"
#include "MbgenNav.h"
#include "mbcore_c.h"
#include "ProceduralMeshComponent.h"
#include "Materials/MaterialInstanceDynamic.h"
#include "Dom/JsonObject.h"
#include "Serialization/JsonSerializer.h"
#include "Misc/FileHelper.h"
#include "Misc/Paths.h"
#include "HAL/PlatformProcess.h"
#include "HAL/PlatformTime.h"
#include "HAL/FileManager.h"
#include "Engine/World.h"
#include "EngineUtils.h"
#include "Components/TextRenderComponent.h"
#include "CollisionQueryParams.h"
#include "UObject/UObjectGlobals.h"
#include "MbgenLibraryWidget.h"
#include "MbgenPropertyWidget.h"
#include "MbgenOutlineWidget.h"
#include "MbgenPackageWidget.h"
#include "MbgenOrbitPawn.h"
#if WITH_EDITOR
#include "MbgenEditorBridge.h"
#endif
#include "UObject/UObjectIterator.h"
#include "MbgenStore.h"

// True geometry stays in micrometres in scene.json. The actor is drawn at
// 20x so a 1 mm PCIe contact pitch is 2 cm and can be framed on its own.
static constexpr float MbgenPreviewScale = 20.f;

static int32 JsonInt(const TSharedPtr<FJsonObject>& Obj, const TCHAR* Field, int32 Fallback = 0)
{
    double V = 0.0;
    if (Obj.IsValid() && Obj->TryGetNumberField(Field, V))
    {
        return (int32)V;
    }
    return Fallback;
}
#if WITH_EDITOR
#include "Editor.h"
#include "LevelEditorViewport.h"
#endif

AMbgenBoardActor::AMbgenBoardActor()
{
    PrimaryActorTick.bCanEverTick = false;
    RootComponent = CreateDefaultSubobject<USceneComponent>(TEXT("Root"));
    ApplySettingsPaths();
    MbgenExe = FPaths::ConvertRelativePathToFull(FPaths::ProjectDir() / TEXT("../../target/debug/mbgen.exe"));
}

void AMbgenBoardActor::BeginPlay()
{
    Super::BeginPlay();
    ApplySettingsPaths();
    EnsureCore();
    RebuildFromDesign();
    FrameOrbit();
    FMbgenStore::Open();
    FString Json;
    if (!FMbgenStore::HasUndoLog() && FFileHelper::LoadFileToString(Json, *DesignFile))
    {
        FMbgenStore::PushUndo(Json, TEXT("open"));
    }
}

void AMbgenBoardActor::EndPlay(const EEndPlayReason::Type EndPlayReason)
{
    CloseCore();
    Super::EndPlay(EndPlayReason);
}

void AMbgenBoardActor::ApplySettingsPaths()
{
    const UMbgenSettings* Settings = GetDefault<UMbgenSettings>();
    FString DesignRel = TEXT("Boards/design.json");
    FString SceneRel = TEXT("Boards/scene.json");
    if (Settings)
    {
        if (!Settings->Design.IsEmpty() && !Settings->Design.Contains(TEXT("mbsim/")))
        {
            DesignRel = Settings->Design;
        }
        if (!Settings->Scene.IsEmpty() && !Settings->Scene.Contains(TEXT("mbsim/")))
        {
            SceneRel = Settings->Scene;
        }
    }
    DesignFile = FPaths::ProjectContentDir() / DesignRel;
    SceneFile = FPaths::ProjectContentDir() / SceneRel;
}

AMbgenBoardActor* AMbgenBoardActor::FindLive(UWorld* Hint)
{
    auto Scan = [](UWorld* World) -> AMbgenBoardActor*
    {
        if (!World) { return nullptr; }
        for (TActorIterator<AMbgenBoardActor> It(World); It; ++It) { return *It; }
        return nullptr;
    };
    if (AMbgenBoardActor* Found = Scan(Hint)) { return Found; }
#if WITH_EDITOR
    if (GEditor)
    {
        if (AMbgenBoardActor* Found = Scan(GEditor->PlayWorld)) { return Found; }
        if (AMbgenBoardActor* Found = Scan(GEditor->GetEditorWorldContext().World())) { return Found; }
    }
#endif
    return nullptr;
}

bool AMbgenBoardActor::IsEditablePart(const FString& Id)
{
    return !Id.IsEmpty() && Id != TEXT("pcb") && Id != TEXT("shield")
        && Id != TEXT("socket_gap") && Id != TEXT("anchor") && !Id.StartsWith(TEXT("err"));
}

bool AMbgenBoardActor::ShouldThrottlePlace() const
{
    const UMbgenSettings* Settings = GetDefault<UMbgenSettings>();
    const int32 Hz = Settings ? FMath::Max(Settings->LiveRouteHz, 1) : 10;
    return (FPlatformTime::Seconds() - LastPlaceTime) < (1.0 / double(Hz));
}

float AMbgenBoardActor::PcbTopCm() const
{
    const FVector* Pcb = BodyCentersCm.Find(TEXT("pcb"));
    const FVector* Sz = BodySizesCm.Find(TEXT("pcb"));
    if (Pcb && Sz) { return (float)(Pcb->Z + Sz->Z * 0.5); }
    return 0.16f;
}

float AMbgenBoardActor::PcbMidCm() const
{
    const FVector* Pcb = BodyCentersCm.Find(TEXT("pcb"));
    return Pcb ? (float)Pcb->Z : 0.08f;
}

float AMbgenBoardActor::PcbBotCm() const
{
    const FVector* Pcb = BodyCentersCm.Find(TEXT("pcb"));
    const FVector* Sz = BodySizesCm.Find(TEXT("pcb"));
    if (Pcb && Sz) { return (float)(Pcb->Z - Sz->Z * 0.5); }
    return 0.0f;
}

bool AMbgenBoardActor::BoardPlaneUm(const FVector& WorldOrigin, const FVector& WorldDir, int64& OutXUm, int64& OutYUm) const
{
    const FTransform Xform = GetActorTransform();
    const FVector LocalOrigin = Xform.InverseTransformPosition(WorldOrigin);
    const FVector LocalDir = Xform.InverseTransformVector(WorldDir);
    if (FMath::Abs(LocalDir.Z) < 1.e-8f)
    {
        return false;
    }
    const float HitT = (PcbTopCm() - LocalOrigin.Z) / LocalDir.Z;
    if (HitT < 0.f)
    {
        return false;
    }
    const FVector Local = LocalOrigin + LocalDir * HitT;
    OutXUm = FMath::RoundToInt64(double(Local.X) / 0.0001);
    OutYUm = FMath::RoundToInt64(double(Local.Y) / 0.0001);
    return true;
}

void AMbgenBoardActor::PlaceSelectedAtRay(const FVector& WorldOrigin, const FVector& WorldDir, bool bFinal)
{
    // The release sample is never dropped by the 10 Hz gate: a drag must end
    // where the cursor is, not where the last accepted throttled sample was.
    if (!IsEditablePart(SelectedId) || (!bFinal && ShouldThrottlePlace()))
    {
        return;
    }
    int64 XUm = 0;
    int64 YUm = 0;
    if (!BoardPlaneUm(WorldOrigin, WorldDir, XUm, YUm))
    {
        return;
    }
    LastPlaceTime = FPlatformTime::Seconds();
    UE_LOG(LogTemp, Display, TEXT("mbgen place %s x_um=%lld y_um=%lld"), *SelectedId, XUm, YUm);
    ApplyGestureJson(FString::Printf(TEXT("{\"op\":\"place\",\"id\":\"%s\",\"x_um\":%lld,\"y_um\":%lld}"), *SelectedId, XUm, YUm), true);
    RefreshPoseFields();
}

void AMbgenBoardActor::NudgeSelectedOnPlane(int32 AlongX, int32 AlongY, bool bFine)
{
    if (!IsEditablePart(SelectedId)) { return; }
    const FVector* Center = BodyCentersCm.Find(SelectedId);
    if (!Center) { return; }
    const int32 Step = bFine ? 100 : 1000;
    const int64 XUm = FMath::RoundToInt64(double(Center->X) / 0.0001) + int64(AlongX) * Step;
    const int64 YUm = FMath::RoundToInt64(double(Center->Y) / 0.0001) + int64(AlongY) * Step;
    ApplyGestureJson(FString::Printf(TEXT("{\"op\":\"place\",\"id\":\"%s\",\"x_um\":%lld,\"y_um\":%lld}"), *SelectedId, XUm, YUm));
}

void AMbgenBoardActor::TurnSelected()
{
    if (!IsEditablePart(SelectedId)) { return; }
    ApplyGestureJson(FString::Printf(TEXT("{\"op\":\"turn\",\"id\":\"%s\"}"), *SelectedId));
}

bool AMbgenBoardActor::HitWorldOnBoard(const FVector& WorldOrigin, const FVector& WorldDir, FVector& OutWorld) const
{
    int64 XUm = 0;
    int64 YUm = 0;
    if (!BoardPlaneUm(WorldOrigin, WorldDir, XUm, YUm)) { return false; }
    const FVector Local(float(XUm) * 0.0001f, float(YUm) * 0.0001f, PcbTopCm());
    OutWorld = GetActorTransform().TransformPosition(Local);
    return true;
}

bool AMbgenBoardActor::NavDeskWorld(FMbgenNavDesk& OutDesk) const
{
    // Finite rest plane in WORLD units, so the shared nav law sees the same
    // numbers the editor viewport and the Play camera report. The actor is a
    // uniform scale + translation; half-extents scale with it.
    const FVector* Pcb = BodyCentersCm.Find(TEXT("pcb"));
    const FVector* Sz = BodySizesCm.Find(TEXT("pcb"));
    if (!Pcb || !Sz) { return false; }
    const FTransform Xform = GetActorTransform();
    const FVector Centre = Xform.TransformPosition(FVector(Pcb->X, Pcb->Y, PcbBotCm()));
    const FVector Half = Xform.TransformVector(FVector(Sz->X * 0.5f, Sz->Y * 0.5f, 0.f)).GetAbs();
    const FMbgenNavDesk Desk = FMbgenNav::Desk(Half.X * 2.0, Half.Y * 2.0, Centre.Z);
    OutDesk = Desk;
    // Desk() centres on the board origin; re-centre on the actual board centre.
    OutDesk.V[0] = Centre.X;
    OutDesk.V[1] = Centre.Y;
    return true;
}

FVector AMbgenBoardActor::NavPickPivotWorld(const FVector& WorldOrigin, const FVector& WorldDir, const FVector& LastPivot) const
{
    FMbgenNavDesk Desk;
    if (!NavDeskWorld(Desk)) { return LastPivot; }
    return FMbgenNav::PickPivot(Desk, WorldOrigin, WorldDir, LastPivot);
}

bool AMbgenBoardActor::HitDeskWorld(const FVector& WorldOrigin, const FVector& WorldDir, FVector& OutWorld) const
{
    const FVector* Pcb = BodyCentersCm.Find(TEXT("pcb"));
    const FVector* Sz = BodySizesCm.Find(TEXT("pcb"));
    if (!Pcb || !Sz) { return false; }
    const FTransform Xform = GetActorTransform();
    const FVector LocalOrigin = Xform.InverseTransformPosition(WorldOrigin);
    FVector LocalDir = Xform.InverseTransformVector(WorldDir);
    if (!LocalDir.Normalize()) { return false; }
    const float Pad = 1.5f;
    const float Cx = Pcb->X;
    const float Cy = Pcb->Y;
    const float Z = PcbBotCm();
    const float Hx = Sz->X * 0.5f * Pad;
    const float Hy = Sz->Y * 0.5f * Pad;
    float X = Cx;
    float Y = Cy;
    if (FMath::Abs(LocalDir.Z) > 1.e-8f)
    {
        const float T = (Z - LocalOrigin.Z) / LocalDir.Z;
        if (T > 0.f)
        {
            const FVector P = LocalOrigin + LocalDir * T;
            X = P.X;
            Y = P.Y;
        }
        else
        {
            X = LocalOrigin.X;
            Y = LocalOrigin.Y;
        }
    }
    else
    {
        X = LocalOrigin.X;
        Y = LocalOrigin.Y;
    }
    X = FMath::Clamp(X, Cx - Hx, Cx + Hx);
    Y = FMath::Clamp(Y, Cy - Hy, Cy + Hy);
    OutWorld = Xform.TransformPosition(FVector(X, Y, Z));
    return true;
}

void AMbgenBoardActor::FinishPlaceDrag()
{
    if (!bPlaceDirty)
    {
        return;
    }
    bPlaceDirty = false;
    RebuildFromDesign();
    RefreshOpenSheets();
    FString Json;
    if (FFileHelper::LoadFileToString(Json, *DesignFile)) { FMbgenStore::PushUndo(Json, TEXT("place")); }
}

static TSet<FString> ReadPortIds(const FString& Path)
{
    TSet<FString> Ids;
    FString Text;
    if (!FFileHelper::LoadFileToString(Text, *Path)) { return Ids; }
    TSharedPtr<FJsonValue> Root;
    TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(Text);
    TSharedPtr<FJsonObject> Design;
    if (!FJsonSerializer::Deserialize(Reader, Root) || !Root.IsValid() || !Root->AsObject()) { return Ids; }
    Design = Root->AsObject();
    const TArray<TSharedPtr<FJsonValue>>* Ports = nullptr;
    if (!Design->TryGetArrayField(TEXT("ports"), Ports) || !Ports) { return Ids; }
    for (const TSharedPtr<FJsonValue>& Item : *Ports)
    {
        const TSharedPtr<FJsonObject> P = Item->AsObject();
        if (P) { Ids.Add(P->GetStringField(TEXT("id"))); }
    }
    return Ids;
}

static TMap<FString, FString> ReadPortRoles(const FString& Path)
{
    TMap<FString, FString> Roles;
    FString Text;
    if (!FFileHelper::LoadFileToString(Text, *Path)) { return Roles; }
    TSharedPtr<FJsonValue> Root;
    TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(Text);
    TSharedPtr<FJsonObject> Design;
    if (!FJsonSerializer::Deserialize(Reader, Root) || !Root.IsValid() || !Root->AsObject()) { return Roles; }
    Design = Root->AsObject();
    const TArray<TSharedPtr<FJsonValue>>* Ports = nullptr;
    if (!Design->TryGetArrayField(TEXT("ports"), Ports) || !Ports) { return Roles; }
    for (const TSharedPtr<FJsonValue>& Item : *Ports)
    {
        const TSharedPtr<FJsonObject> P = Item->AsObject();
        if (P) { Roles.Add(P->GetStringField(TEXT("id")), P->GetStringField(TEXT("role"))); }
    }
    return Roles;
}

FString AMbgenBoardActor::PortRole(const FString& Id) const
{
    if (Id.IsEmpty()) { return FString(); }
    const TMap<FString, FString> Roles = ReadPortRoles(DesignFile);
    if (const FString* Found = Roles.Find(Id)) { return *Found; }
    return FString();
}

FString AMbgenBoardActor::PropertyHostId() const
{
    const TMap<FString, FString> Roles = ReadPortRoles(DesignFile);
    if (IsEditablePart(SelectedId) && Roles.Contains(SelectedId)) { return SelectedId; }
    for (const TPair<FString, FString>& Pair : Roles)
    {
        if (Pair.Value == TEXT("socket")) { return Pair.Key; }
    }
    for (const TPair<FString, FString>& Pair : Roles)
    {
        if (IsEditablePart(Pair.Key)) { return Pair.Key; }
    }
    return FString();
}

void AMbgenBoardActor::DropRoleAtRay(const FString& RoleId, const FVector& WorldOrigin, const FVector& WorldDir)
{
    if (RoleId.IsEmpty()) { return; }
    int64 XUm = 0;
    int64 YUm = 0;
    if (!BoardPlaneUm(WorldOrigin, WorldDir, XUm, YUm))
    {
        UE_LOG(LogTemp, Display, TEXT("mbgen drop %s missed the board"), *RoleId);
        return;
    }
    const TSet<FString> Before = ReadPortIds(DesignFile);
    ApplyGestureJson(FString::Printf(TEXT("{\"op\":\"add\",\"role\":\"%s\"}"), *RoleId));
    const TSet<FString> After = ReadPortIds(DesignFile);
    FString NewId;
    for (const FString& Id : After)
    {
        if (!Before.Contains(Id)) { NewId = Id; break; }
    }
    if (NewId.IsEmpty())
    {
        UE_LOG(LogTemp, Display, TEXT("mbgen drop %s kept the previous design"), *RoleId);
        return;
    }
    SelectedId = NewId;
    ApplyGestureJson(FString::Printf(TEXT("{\"op\":\"place\",\"id\":\"%s\",\"x_um\":%lld,\"y_um\":%lld}"), *NewId, XUm, YUm));
    RefreshLabels();
    SelectPart(NewId);
    RecaptureThumb(RoleId);
    UE_LOG(LogTemp, Display, TEXT("mbgen drop %s id=%s x_um=%lld y_um=%lld"), *RoleId, *NewId, XUm, YUm);
}

void AMbgenBoardActor::RefreshSolderTextures()
{
    const FString TexDir = FPaths::ProjectContentDir() / TEXT("Textures");
    FString Log;
    const FString Args = FString::Printf(TEXT("textures --design \"%s\" --out \"%s\""), *DesignFile, *TexDir);
    if (!RunTool(Args, Log))
    {
        UE_LOG(LogTemp, Warning, TEXT("mbgen textures failed"));
        return;
    }
    UE_LOG(LogTemp, Display, TEXT("mbgen textures wrote"));
    ClearPreviewMeshes();
    CollectGarbage(GARBAGE_COLLECTION_KEEPFLAGS, true);
#if WITH_EDITOR
    if (GEditor)
    {
        GEditor->Exec(nullptr, TEXT("py import mbgen_materials; mbgen_materials.reimport_solder_maps()"));
    }
#endif
}

void AMbgenBoardActor::RefreshLabels()
{
#if WITH_EDITOR
    if (GEditor)
    {
        GEditor->Exec(nullptr, TEXT("py import mbgen_materials; mbgen_materials.refresh_labels()"));
    }
#endif
    RebuildFromDesign();
}

void AMbgenBoardActor::RecaptureThumb(const FString& RoleId)
{
#if WITH_EDITOR
    if (!GEditor || RoleId.IsEmpty()) { return; }
    const FString Safe = RoleId.Replace(TEXT("\""), TEXT("")).Replace(TEXT("'"), TEXT(""));
    GEditor->Exec(nullptr, *FString::Printf(
        TEXT("py import mbgen_materials; mbgen_materials.capture_library_thumbs(True, \"%s\")"),
        *Safe));
    UMbgenLibraryWidget::RefreshOpenLists();
#endif
}

void AMbgenBoardActor::RefreshLibraryFile()
{
    EnsureCore();
    const FString Path = FPaths::ProjectContentDir() / TEXT("Boards/library.json");
    if (bDllOk && FnLibrary && FnFree)
    {
        using LibFn = char*(*)();
        using FreeFn = void(*)(char*);
        char* Raw = ((LibFn)FnLibrary)();
        if (Raw)
        {
            const FString Text = UTF8_TO_TCHAR(Raw);
            ((FreeFn)FnFree)(Raw);
            WriteUtf8(Path, Text);
            UE_LOG(LogTemp, Display, TEXT("mbgen library json=mbcore"));
            return;
        }
    }
    FString Log;
    if (RunTool(FString::Printf(TEXT("library --out \"%s\""), *Path), Log))
    {
        UE_LOG(LogTemp, Display, TEXT("mbgen library json=exe"));
    }
}

void AMbgenBoardActor::CopySelected()
{
    CopyPartToStore();
    if (!IsEditablePart(SelectedId)) { return; }
    const TSet<FString> Before = ReadPortIds(DesignFile);
    ApplyGestureJson(FString::Printf(TEXT("{\"op\":\"copy\",\"id\":\"%s\"}"), *SelectedId));
    const TSet<FString> After = ReadPortIds(DesignFile);
    FString NewId;
    for (const FString& Id : After)
    {
        if (!Before.Contains(Id)) { NewId = Id; break; }
    }
    if (NewId.IsEmpty())
    {
        UE_LOG(LogTemp, Display, TEXT("mbgen copy %s kept the previous design"), *SelectedId);
        return;
    }
    RefreshLabels();
    SelectPart(NewId);
}

void AMbgenBoardActor::AddRole(const FString& RoleId)
{
    if (RoleId.IsEmpty()) { return; }
    const TSet<FString> Before = ReadPortIds(DesignFile);
    ApplyGestureJson(FString::Printf(TEXT("{\"op\":\"add\",\"role\":\"%s\"}"), *RoleId));
    const TSet<FString> After = ReadPortIds(DesignFile);
    FString NewId;
    for (const FString& Id : After)
    {
        if (!Before.Contains(Id)) { NewId = Id; break; }
    }
    if (NewId.IsEmpty())
    {
        UE_LOG(LogTemp, Display, TEXT("mbgen add %s kept the previous design"), *RoleId);
        return;
    }
    RefreshLabels();
    SelectPart(NewId);
    RecaptureThumb(RoleId);
}

void AMbgenBoardActor::SelectPart(const FString& Id)
{
    SelectedId = Id;
    PaintAnchors();
    RefreshOpenSheets();
    UE_LOG(LogTemp, Display, TEXT("mbgen selected %s"), *SelectedId);
}

void AMbgenBoardActor::RefreshOpenSheets()
{
    for (TObjectIterator<UMbgenPropertyWidget> It; It; ++It)
    {
        if (IsValid(*It)) { It->ShowPart(SelectedId); }
    }
}

void AMbgenBoardActor::RefreshPoseFields()
{
    for (TObjectIterator<UMbgenPropertyWidget> It; It; ++It)
    {
        if (IsValid(*It)) { It->RefreshPose(); }
    }
}

bool AMbgenBoardActor::PartXyUm(const FString& Id, int64& OutXUm, int64& OutYUm) const
{
    const FVector* Center = BodyCentersCm.Find(Id);
    if (Center)
    {
        OutXUm = FMath::RoundToInt64(double(Center->X) / 0.0001);
        OutYUm = FMath::RoundToInt64(double(Center->Y) / 0.0001);
        return true;
    }
    return false;
}

void AMbgenBoardActor::ReloadDesignFromDisk()
{
    CloseCore();
    bDllTried = false;
    FString Out;
    RunTool(FString::Printf(TEXT("scene --design \"%s\" --out \"%s\""), *DesignFile, *SceneFile), Out);
    EnsureCore();
    RebuildFromDesign();
    RefreshOpenSheets();
}

void AMbgenBoardActor::CopyPartToStore()
{
    if (!IsEditablePart(SelectedId)) { return; }
    int64 XUm = 0;
    int64 YUm = 0;
    PartXyUm(SelectedId, XUm, YUm);
    const FString PartRole = PortRole(SelectedId);
    int32 Yaw = 0;
    FString DesignText;
    if (FFileHelper::LoadFileToString(DesignText, *DesignFile))
    {
        TSharedPtr<FJsonValue> Root;
        TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(DesignText);
        TSharedPtr<FJsonObject> Design;
        if (FJsonSerializer::Deserialize(Reader, Root) && Root.IsValid() && Root->AsObject())
        {
            Design = Root->AsObject();
            const TArray<TSharedPtr<FJsonValue>>* Places = nullptr;
            if (Design->TryGetArrayField(TEXT("placements"), Places))
            {
                for (const TSharedPtr<FJsonValue>& Item : *Places)
                {
                    const TSharedPtr<FJsonObject> P = Item->AsObject();
                    if (P && P->GetStringField(TEXT("id")) == SelectedId)
                    {
                        Yaw = JsonInt(P, TEXT("yaw_q"));
                        break;
                    }
                }
            }
        }
    }
    const FString Clip = FString::Printf(TEXT("{\"role\":\"%s\",\"x_um\":%lld,\"y_um\":%lld,\"yaw_q\":%d}"), *PartRole, XUm, YUm, Yaw);
    FMbgenStore::SetClipboard(Clip);
    UE_LOG(LogTemp, Display, TEXT("mbgen copy %s"), *SelectedId);
}

void AMbgenBoardActor::PastePartFromStore()
{
    FString Clip;
    if (!FMbgenStore::GetClipboard(Clip)) { return; }
    TSharedPtr<FJsonObject> Obj;
    TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(Clip);
    if (!FJsonSerializer::Deserialize(Reader, Obj) || !Obj) { return; }
    const FString PartRole = Obj->GetStringField(TEXT("role"));
    const int64 XUm = (int64)Obj->GetNumberField(TEXT("x_um")) + 2000;
    const int64 YUm = (int64)Obj->GetNumberField(TEXT("y_um"));
    const int32 Yaw = JsonInt(Obj, TEXT("yaw_q"));
    if (PartRole.IsEmpty()) { return; }
    const TSet<FString> Before = ReadPortIds(DesignFile);
    ApplyGestureJson(FString::Printf(TEXT("{\"op\":\"add\",\"role\":\"%s\"}"), *PartRole));
    const TSet<FString> After = ReadPortIds(DesignFile);
    FString NewId;
    for (const FString& Id : After)
    {
        if (!Before.Contains(Id)) { NewId = Id; break; }
    }
    if (NewId.IsEmpty()) { return; }
    ApplyGestureJson(FString::Printf(TEXT("{\"op\":\"place\",\"id\":\"%s\",\"x_um\":%lld,\"y_um\":%lld}"), *NewId, XUm, YUm));
    for (int32 i = 0; i < (Yaw % 4 + 4) % 4; ++i)
    {
        ApplyGestureJson(FString::Printf(TEXT("{\"op\":\"turn\",\"id\":\"%s\"}"), *NewId));
    }
    RefreshLabels();
    SelectPart(NewId);
    RecaptureThumb(PartRole);
    UE_LOG(LogTemp, Display, TEXT("mbgen paste %s"), *NewId);
}

void AMbgenBoardActor::DiagnoseNav()
{
#if WITH_EDITOR
    FMbgenEditorBridge::DiagnoseNav();
#endif
}

bool AMbgenBoardActor::DeskCornersWorld(FVector OutCorners[4]) const
{
    const FVector* Pcb = BodyCentersCm.Find(TEXT("pcb"));
    const FVector* Sz = BodySizesCm.Find(TEXT("pcb"));
    if (!Pcb || !Sz) { return false; }
    const float Pad = 1.5f;
    const float Hx = Sz->X * 0.5f * Pad;
    const float Hy = Sz->Y * 0.5f * Pad;
    const float Z = PcbBotCm();
    const FVector Local[4] = {
        FVector(Pcb->X - Hx, Pcb->Y - Hy, Z),
        FVector(Pcb->X + Hx, Pcb->Y - Hy, Z),
        FVector(Pcb->X + Hx, Pcb->Y + Hy, Z),
        FVector(Pcb->X - Hx, Pcb->Y + Hy, Z),
    };
    const FTransform Xform = GetActorTransform();
    for (int32 i = 0; i < 4; ++i) { OutCorners[i] = Xform.TransformPosition(Local[i]); }
    return true;
}

void AMbgenBoardActor::FrameOrbit()
{
    const FVector* Pcb = BodyCentersCm.Find(TEXT("pcb"));
    const FVector Local = Pcb ? *Pcb : FVector::ZeroVector;
    const FVector World = GetActorTransform().TransformPosition(Local);
#if WITH_EDITOR
    FMbgenEditorBridge::FrameOrbit(World);
#endif
    if (UWorld* WorldPtr = GetWorld())
    {
        for (TActorIterator<AMbgenOrbitPawn> It(WorldPtr); It; ++It)
        {
            It->FrameOn(World);
        }
    }
    UE_LOG(LogTemp, Display, TEXT("mbgen frame %.0f %.0f %.0f"), World.X, World.Y, World.Z);
}

void AMbgenBoardActor::DeleteSelected()
{
    if (!IsEditablePart(SelectedId))
    {
        return;
    }
    const FString Id = SelectedId;
    SelectedId.Empty();
    ApplyGestureJson(FString::Printf(TEXT("{\"op\":\"delete\",\"id\":\"%s\"}"), *Id));
    PaintAnchors();
    RefreshOpenSheets();
    UE_LOG(LogTemp, Display, TEXT("mbgen selected"));
}

void AMbgenBoardActor::ClearPreviewMeshes()
{
    for (UProceduralMeshComponent* Section : Sections)
    {
        if (Section)
        {
            Section->SetMaterial(0, nullptr);
            Section->DestroyComponent();
        }
    }
    Sections.Reset();
    for (UProceduralMeshComponent* Mark : AnchorMarks)
    {
        if (Mark)
        {
            Mark->SetMaterial(0, nullptr);
            Mark->DestroyComponent();
        }
    }
    AnchorMarks.Reset();
    for (UProceduralMeshComponent* Strip : PathStrips)
    {
        if (Strip)
        {
            Strip->SetMaterial(0, nullptr);
            Strip->DestroyComponent();
        }
    }
    PathStrips.Reset();
    TArray<UActorComponent*> OldLabels;
    GetComponents(UTextRenderComponent::StaticClass(), OldLabels);
    for (UActorComponent* Label : OldLabels)
    {
        if (Label) { Label->DestroyComponent(); }
    }
}

void AMbgenBoardActor::RebuildFromDesign()
{
    EnsureCore();
    ClearPreviewMeshes();
    FString Text;
    if (!FFileHelper::LoadFileToString(Text, *SceneFile))
    {
        UE_LOG(LogTemp, Warning, TEXT("mbgen scene missing: %s"), *SceneFile);
        return;
    }
    TSharedPtr<FJsonValue> Root;
    TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(Text);
    if (!FJsonSerializer::Deserialize(Reader, Root) || !Root.IsValid() || Root->Type != EJson::Array)
    {
        return;
    }
    RememberScenePoses();
    for (const TSharedPtr<FJsonValue>& Item : Root->AsArray())
    {
        const TSharedPtr<FJsonObject> Obj = Item->AsObject();
        if (!Obj) { continue; }
        const double X = Obj->GetNumberField(TEXT("x_um"));
        const double Y = Obj->GetNumberField(TEXT("y_um"));
        const double Z = Obj->GetNumberField(TEXT("z_um"));
        const double SX = Obj->GetNumberField(TEXT("sx_um"));
        const double SY = Obj->GetNumberField(TEXT("sy_um"));
        const double SZ = Obj->GetNumberField(TEXT("sz_um"));
        const FString Material = Obj->GetStringField(TEXT("material"));
        const FString Support = Obj->GetStringField(TEXT("support"));
        FLinearColor Color(0.05f, 0.32f, 0.16f);
        if (Material == TEXT("metal")) Color = FLinearColor(0.72f, 0.73f, 0.75f);
        else if (Material == TEXT("plastic")) Color = FLinearColor(0.12f, 0.12f, 0.13f);
        else if (Material == TEXT("gold")) Color = FLinearColor(0.83f, 0.66f, 0.22f);
        else if (Material == TEXT("ceramic")) Color = FLinearColor(0.74f, 0.71f, 0.62f);
        else if (Material == TEXT("ghost") || Support == TEXT("gap")) Color = FLinearColor(0.85f, 0.28f, 0.08f);
        const float ToCm = 0.0001f;
        AddBox(FVector(X * ToCm, Y * ToCm, Z * ToCm), FVector(SX * ToCm, SY * ToCm, SZ * ToCm), Color, Material, Obj->GetStringField(TEXT("id")), Obj->GetStringField(TEXT("role")), JsonInt(Obj, TEXT("yaw_q")));
        if (Support == TEXT("gap") || Material == TEXT("ghost"))
        {
            PlaceBadge(
                FVector(X * ToCm, Y * ToCm, Z * ToCm + SZ * ToCm * 0.5f + 0.12f),
                TEXT("GAP"),
                Obj->GetStringField(TEXT("id")),
                FColor(220, 90, 40));
        }
    }
    SetActorScale3D(FVector(MbgenPreviewScale));
    if (!SelectedId.IsEmpty() && (!IsEditablePart(SelectedId) || !BodyCentersCm.Contains(SelectedId)))
    {
        SelectedId.Empty();
    }
    PaintGapBadges();
    PaintAnchors();
    static bool bSeededUndo = false;
    if (!bSeededUndo)
    {
        FMbgenStore::Open();
        FString Json;
        if (!FMbgenStore::HasUndoLog() && FFileHelper::LoadFileToString(Json, *DesignFile))
        {
            FMbgenStore::PushUndo(Json, TEXT("seed"));
        }
        bSeededUndo = true;
    }
}

void AMbgenBoardActor::PlaceBadge(const FVector& CenterCm, const FString& Text, const FString& Tag, const FColor& Color)
{
    UTextRenderComponent* Label = NewObject<UTextRenderComponent>(this);
    Label->SetCanEverAffectNavigation(false);
    Label->SetupAttachment(RootComponent);
    Label->SetCollisionEnabled(ECollisionEnabled::NoCollision);
    Label->SetRelativeLocation(CenterCm);
    Label->SetRelativeRotation(FRotator(90.f, 0.f, 0.f));
    Label->SetHorizontalAlignment(EHTA_Center);
    Label->SetVerticalAlignment(EVRTA_TextCenter);
    Label->SetWorldSize(0.32f);
    Label->SetTextRenderColor(Color);
    Label->SetText(FText::FromString(Text));
    Label->ComponentTags.Add(FName(*Tag));
    Label->RegisterComponent();
}

void AMbgenBoardActor::ClearBadgesWithTag(const FString& Tag)
{
    TArray<UActorComponent*> Labels;
    GetComponents(UTextRenderComponent::StaticClass(), Labels);
    for (UActorComponent* Comp : Labels)
    {
        if (!Comp || Comp->ComponentTags.Num() == 0) { continue; }
        if (Comp->ComponentTags[0].ToString() == Tag)
        {
            Comp->DestroyComponent();
        }
    }
}

void AMbgenBoardActor::PaintGapBadges()
{
    int32 Gap = 0;
    TArray<UActorComponent*> Labels;
    GetComponents(UTextRenderComponent::StaticClass(), Labels);
    for (UActorComponent* Comp : Labels)
    {
        if (UTextRenderComponent* Text = Cast<UTextRenderComponent>(Comp))
        {
            if (Text->Text.ToString() == TEXT("GAP")) { Gap += 1; }
        }
    }
    int32 SocketMissing = 0;
    FString DesignText;
    if (FFileHelper::LoadFileToString(DesignText, *DesignFile))
    {
        TSharedPtr<FJsonValue> Root;
        TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(DesignText);
        TSharedPtr<FJsonObject> Design;
        if (FJsonSerializer::Deserialize(Reader, Root) && Root.IsValid() && Root->AsObject())
        {
            Design = Root->AsObject();
            bool bHasSocket = false;
            const TArray<TSharedPtr<FJsonValue>>* Ports = nullptr;
            if (Design->TryGetArrayField(TEXT("ports"), Ports) && Ports)
            {
                for (const TSharedPtr<FJsonValue>& Item : *Ports)
                {
                    const TSharedPtr<FJsonObject> P = Item->AsObject();
                    if (P && P->GetStringField(TEXT("role")) == TEXT("socket")) { bHasSocket = true; break; }
                }
            }
            const FString TemplateId = Design->GetStringField(TEXT("template_id"));
            if (!bHasSocket)
            {
                FString OutlineText;
                const FString OutlinePath = FPaths::ProjectContentDir() / TEXT("Boards/outlines.json");
                if (FFileHelper::LoadFileToString(OutlineText, *OutlinePath))
                {
                    TSharedPtr<FJsonValue> OutRoot;
                    TSharedRef<TJsonReader<>> OutReader = TJsonReaderFactory<>::Create(OutlineText);
                    if (FJsonSerializer::Deserialize(OutReader, OutRoot) && OutRoot.IsValid() && OutRoot->Type == EJson::Array)
                    {
                        for (const TSharedPtr<FJsonValue>& Item : OutRoot->AsArray())
                        {
                            const TSharedPtr<FJsonObject> Row = Item->AsObject();
                            if (!Row || Row->GetStringField(TEXT("id")) != TemplateId) { continue; }
                            if (!Row->GetBoolField(TEXT("has_cpu"))) { break; }
                            const float ToCm = 0.0001f;
                            const double W = Row->GetNumberField(TEXT("w_um"));
                            const double D = Row->GetNumberField(TEXT("d_um"));
                            const double Frac = Row->GetNumberField(TEXT("cpu_y_frac"));
                            const FVector At(W * 0.5 * ToCm, D * (Frac / 100.0) * ToCm, PcbTopCm() + 0.22f);
                            PlaceBadge(At, TEXT("SOCKET GAP"), TEXT("socket_gap"), FColor(220, 90, 40));
                            SocketMissing = 1;
                            break;
                        }
                    }
                }
            }
        }
    }
    UE_LOG(LogTemp, Display, TEXT("mbgen badges gap=%d socket=%d"), Gap, SocketMissing);
}

void AMbgenBoardActor::PaintNetErrorBadges(const TArray<TSharedPtr<FJsonValue>>* Errors)
{
    ClearBadgesWithTag(TEXT("err"));
    if (!Errors) { return; }
    int32 Painted = 0;
    for (const TSharedPtr<FJsonValue>& Item : *Errors)
    {
        const TSharedPtr<FJsonObject> E = Item->AsObject();
        if (!E) { continue; }
        FString Kind;
        E->TryGetStringField(TEXT("kind"), Kind);
        if (Kind == TEXT("GapRole") || Kind.IsEmpty()) { continue; }
        FString Pin;
        E->TryGetStringField(TEXT("pin"), Pin);
        FString Part = Pin;
        int32 Dot = INDEX_NONE;
        if (Pin.FindChar(TEXT('.'), Dot)) { Part = Pin.Left(Dot); }
        const FVector* Center = BodyCentersCm.Find(Part);
        const FVector* Size = BodySizesCm.Find(Part);
        if (!Center) { continue; }
        FString Label = TEXT("OPEN");
        if (Kind == TEXT("Unroutable")) { Label = TEXT("UNROUTABLE"); }
        else if (Kind == TEXT("DomainClash")) { Label = TEXT("DOMAIN"); }
        else if (Kind == TEXT("Courtyard")) { Label = TEXT("COURTYARD"); }
        const FVector At = *Center + FVector(0.f, 0.f, Size ? Size->Z * 0.5f + 0.18f : 0.30f);
        PlaceBadge(At, Label, TEXT("err"), FColor(230, 50, 40));
        Painted += 1;
    }
    if (Painted > 0)
    {
        UE_LOG(LogTemp, Display, TEXT("mbgen badges errors=%d"), Painted);
    }
}

static UProceduralMeshComponent* MakeWell(AActor* Owner, USceneComponent* Root, const FVector& Center, const FVector& Size, const TCHAR* Slot)
{
    if (Size.GetAbs().GetMax() < 0.02) { return nullptr; }
    UProceduralMeshComponent* Well = NewObject<UProceduralMeshComponent>(Owner);
    Well->SetCanEverAffectNavigation(false);
    Well->SetupAttachment(Root);
    Well->SetCollisionEnabled(ECollisionEnabled::NoCollision);
    const FVector WH = Size * 0.5f;
    TArray<FVector> WV;
    TArray<int32> WI;
    TArray<FVector> WN;
    TArray<FVector2D> WUV;
    TArray<FLinearColor> WC;
    TArray<FProcMeshTangent> WT;
    const FVector WellCorners[8] = {
        Center + FVector(-WH.X,-WH.Y,-WH.Z), Center + FVector(WH.X,-WH.Y,-WH.Z),
        Center + FVector(WH.X,WH.Y,-WH.Z), Center + FVector(-WH.X,WH.Y,-WH.Z),
        Center + FVector(-WH.X,-WH.Y,WH.Z), Center + FVector(WH.X,-WH.Y,WH.Z),
        Center + FVector(WH.X,WH.Y,WH.Z), Center + FVector(-WH.X,WH.Y,WH.Z)
    };
    const int32 WellFaces[6][4] = {{4,5,6,7},{0,3,2,1},{3,7,6,2},{0,1,5,4},{1,2,6,5},{0,4,7,3}};
    for (int32 f = 0; f < 6; ++f)
    {
        const int32 b = WV.Num();
        const FVector EdgeU = WellCorners[WellFaces[f][1]] - WellCorners[WellFaces[f][0]];
        const FVector FaceN = FVector::CrossProduct(EdgeU, WellCorners[WellFaces[f][2]] - WellCorners[WellFaces[f][0]]).GetSafeNormal();
        const FProcMeshTangent FaceTan(EdgeU.GetSafeNormal(), false);
        for (int32 k = 0; k < 4; ++k)
        {
            WV.Add(WellCorners[WellFaces[f][k]]);
            WC.Add(FLinearColor::White);
            WUV.Add(FVector2D(k==1||k==2, k>=2));
            WN.Add(FaceN);
            WT.Add(FaceTan);
        }
        WI.Append({b, b+1, b+2, b, b+2, b+3});
    }
    Well->CreateMeshSection_LinearColor(0, WV, WI, WN, WUV, WC, WT, false);
    const FString WellPath = FString::Printf(TEXT("/Game/Materials/MSlot_%s.MSlot_%s"), Slot, Slot);
    UMaterialInterface* Mat = LoadObject<UMaterialInterface>(nullptr, *WellPath);
    if (!Mat)
    {
        Well->DestroyComponent();
        return nullptr;
    }
    Well->SetMaterial(0, Mat);
    Well->RegisterComponent();
    return Well;
}

void AMbgenBoardActor::PaintAnchors()
{
    for (UProceduralMeshComponent* Mark : AnchorMarks)
    {
        if (Mark) { Mark->DestroyComponent(); }
    }
    AnchorMarks.Reset();
    if (!IsEditablePart(SelectedId)) { return; }
    const float ToCm = 0.0001f;
    auto PlaceTick = [&](double XUm, double YUm, double ZUm, const FString& Kind)
    {
        const FVector Tick = Kind == TEXT("PinPad") ? FVector(0.05f, 0.05f, 0.05f) : FVector(0.08f, 0.08f, 0.08f);
        const FVector At(XUm * ToCm, YUm * ToCm, ZUm * ToCm + 0.05f);
        UProceduralMeshComponent* Well = MakeWell(this, RootComponent, At, Tick, TEXT("pin"));
        if (!Well) { return; }
        Well->ComponentTags.Add(FName(*SelectedId));
        Well->ComponentTags.Add(FName(TEXT("anchor")));
        AnchorMarks.Add(Well);
    };
    auto PaintFromJson = [&](const FString& Text) -> bool
    {
        TSharedPtr<FJsonValue> Root;
        TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(Text);
        if (!FJsonSerializer::Deserialize(Reader, Root) || !Root.IsValid() || Root->Type != EJson::Array)
        {
            return false;
        }
        for (const TSharedPtr<FJsonValue>& Item : Root->AsArray())
        {
            const TSharedPtr<FJsonObject> Obj = Item->AsObject();
            if (!Obj || Obj->GetStringField(TEXT("part")) != SelectedId) { continue; }
            PlaceTick(Obj->GetNumberField(TEXT("x_um")), Obj->GetNumberField(TEXT("y_um")), Obj->GetNumberField(TEXT("z_um")), Obj->GetStringField(TEXT("kind")));
        }
        return AnchorMarks.Num() > 0;
    };
    FString Src = TEXT("aabb");
    EnsureCore();
    if (bDllOk && FnAnchors && FnFree)
    {
        using OpenFn = mb_session*(*)(const char*);
        using AnchorsFn = char*(*)(mb_session*);
        using FreeFn = void(*)(char*);
        if (!CoreSession)
        {
            FString DesignText;
            if (FFileHelper::LoadFileToString(DesignText, *DesignFile))
            {
                const FTCHARToUTF8 DesignUtf8(*DesignText);
                CoreSession = ((OpenFn)FnOpen)(DesignUtf8.Get());
            }
        }
        if (CoreSession)
        {
            char* Raw = ((AnchorsFn)FnAnchors)((mb_session*)CoreSession);
            if (Raw)
            {
                const FString Text = UTF8_TO_TCHAR(Raw);
                ((FreeFn)FnFree)(Raw);
                if (PaintFromJson(Text)) { Src = TEXT("mbcore"); }
            }
        }
    }
    if (Src == TEXT("aabb"))
    {
        const FString OutPath = FPaths::ProjectSavedDir() / TEXT("anchors.json");
        FString Log;
        const FString Args = FString::Printf(TEXT("anchors --design \"%s\" --out \"%s\""), *DesignFile, *OutPath);
        FString Text;
        if (RunTool(Args, Log) && FFileHelper::LoadFileToString(Text, *OutPath) && PaintFromJson(Text))
        {
            Src = TEXT("exe");
        }
    }
    if (Src == TEXT("aabb"))
    {
        const FVector* Center = BodyCentersCm.Find(SelectedId);
        const FVector* Size = BodySizesCm.Find(SelectedId);
        if (Center && Size)
        {
            const FVector H = *Size * 0.5f;
            const float Lift = Center->Z + H.Z;
            PlaceTick(Center->X / ToCm, Center->Y / ToCm, Lift / ToCm, TEXT("EdgeS"));
            PlaceTick((Center->X - H.X) / ToCm, (Center->Y - H.Y) / ToCm, Lift / ToCm, TEXT("Courtyard"));
            PlaceTick((Center->X + H.X) / ToCm, (Center->Y - H.Y) / ToCm, Lift / ToCm, TEXT("Courtyard"));
            PlaceTick((Center->X - H.X) / ToCm, (Center->Y + H.Y) / ToCm, Lift / ToCm, TEXT("Courtyard"));
            PlaceTick((Center->X + H.X) / ToCm, (Center->Y + H.Y) / ToCm, Lift / ToCm, TEXT("Courtyard"));
        }
    }
    UE_LOG(LogTemp, Display, TEXT("mbgen anchors id=%s n=%d src=%s"), *SelectedId, AnchorMarks.Num(), *Src);
}

static void AddFace(
    TArray<FVector>& V, TArray<int32>& I, TArray<FVector>& N, TArray<FVector2D>& UV,
    TArray<FLinearColor>& Col, TArray<FProcMeshTangent>& Tan,
    const FVector& A, const FVector& B, const FVector& P2, const FVector& P3, const FLinearColor& Color)
{
    const int32 b = V.Num();
    const FVector EdgeU = B - A;
    const FVector FaceN = FVector::CrossProduct(EdgeU, P2 - A).GetSafeNormal();
    const FProcMeshTangent FaceTan(EdgeU.GetSafeNormal(), false);
    const FVector Quad[4] = {A, B, P2, P3};
    for (int32 k = 0; k < 4; ++k)
    {
        V.Add(Quad[k]);
        Col.Add(Color);
        UV.Add(FVector2D(k==1||k==2, k>=2));
        N.Add(FaceN);
        Tan.Add(FaceTan);
    }
    I.Append({b, b+1, b+2, b, b+2, b+3});
}

static UProceduralMeshComponent* MakePinRow(AActor* Owner, USceneComponent* Root, const FVector& Center, const FVector& Along, int32 Count, float Pitch, const FVector& PinSize, const TCHAR* Slot, const FVector& HeadLean)
{
    if (Count < 1 || PinSize.GetAbs().GetMax() < 0.01) { return nullptr; }
    const FVector Dir = Along.GetSafeNormal();
    const FVector Side = FVector::CrossProduct(Dir, FVector::UpVector).GetSafeNormal();
    const FVector Up = FVector::CrossProduct(Side, Dir).GetSafeNormal();
    UProceduralMeshComponent* Row = NewObject<UProceduralMeshComponent>(Owner);
    Row->SetCanEverAffectNavigation(false);
    Row->SetupAttachment(Root);
    Row->SetCollisionEnabled(ECollisionEnabled::NoCollision);
    TArray<FVector> V;
    TArray<int32> Idx;
    TArray<FVector> Nrm;
    TArray<FVector2D> UV;
    TArray<FLinearColor> Col;
    TArray<FProcMeshTangent> Tan;
    auto BoxAt = [&](const FVector& O, float Depth, float Wide, float Tall)
    {
        const FVector Ax = Side * (Depth * 0.5f);
        const FVector Ay = Dir * (Wide * 0.5f);
        const FVector Az = Up * (Tall * 0.5f);
        const FVector Q0 = O - Ax - Ay - Az;
        const FVector Q1 = O + Ax - Ay - Az;
        const FVector Q2 = O + Ax + Ay - Az;
        const FVector Q3 = O - Ax + Ay - Az;
        const FVector Q4 = O - Ax - Ay + Az;
        const FVector Q5 = O + Ax - Ay + Az;
        const FVector Q6 = O + Ax + Ay + Az;
        const FVector Q7 = O - Ax + Ay + Az;
        AddFace(V, Idx, Nrm, UV, Col, Tan, Q4, Q5, Q6, Q7, FLinearColor::White);
        AddFace(V, Idx, Nrm, UV, Col, Tan, Q0, Q3, Q2, Q1, FLinearColor::White);
        AddFace(V, Idx, Nrm, UV, Col, Tan, Q0, Q1, Q5, Q4, FLinearColor::White);
        AddFace(V, Idx, Nrm, UV, Col, Tan, Q3, Q7, Q6, Q2, FLinearColor::White);
        AddFace(V, Idx, Nrm, UV, Col, Tan, Q1, Q2, Q6, Q5, FLinearColor::White);
        AddFace(V, Idx, Nrm, UV, Col, Tan, Q0, Q4, Q7, Q3, FLinearColor::White);
    };
    auto Frustum = [&](const FVector& Bottom, const FVector& Top, float DepthB, float WideB, float DepthT, float WideT)
    {
        const FVector Ab = Side * (DepthB * 0.5f);
        const FVector At = Side * (DepthT * 0.5f);
        const FVector Yb = Dir * (WideB * 0.5f);
        const FVector Yt = Dir * (WideT * 0.5f);
        const FVector B0 = Bottom - Ab - Yb;
        const FVector B1 = Bottom + Ab - Yb;
        const FVector B2 = Bottom + Ab + Yb;
        const FVector B3 = Bottom - Ab + Yb;
        const FVector T0 = Top - At - Yt;
        const FVector T1 = Top + At - Yt;
        const FVector T2 = Top + At + Yt;
        const FVector T3 = Top - At + Yt;
        AddFace(V, Idx, Nrm, UV, Col, Tan, T0, T1, T2, T3, FLinearColor::White);
        AddFace(V, Idx, Nrm, UV, Col, Tan, B0, B3, B2, B1, FLinearColor::White);
        AddFace(V, Idx, Nrm, UV, Col, Tan, B0, B1, T1, T0, FLinearColor::White);
        AddFace(V, Idx, Nrm, UV, Col, Tan, B3, T3, T2, B2, FLinearColor::White);
        AddFace(V, Idx, Nrm, UV, Col, Tan, B1, B2, T2, T1, FLinearColor::White);
        AddFace(V, Idx, Nrm, UV, Col, Tan, B0, T0, T3, B3, FLinearColor::White);
    };
    const float Span = (Count - 1) * Pitch;
    const float RootW = PinSize.Y * 0.40f;
    const float TipW = FMath::Min(PinSize.Y * 0.92f, Pitch * 0.56f);
    for (int32 i = 0; i < Count; ++i)
    {
        const FVector O = Center + Dir * (i * Pitch - Span * 0.5f);
        const FVector Base = O - Up * (PinSize.Z * 0.34f);
        const FVector Tip = O + Up * (PinSize.Z * 0.16f) + HeadLean * 0.55f;
        const FVector Nose = Tip + HeadLean * 0.70f + Up * (PinSize.Z * 0.10f);
        Frustum(Base, Tip, PinSize.X * 0.90f, RootW, PinSize.X * 0.30f, TipW);
        BoxAt(Nose, PinSize.X * 0.20f, TipW, PinSize.Z * 0.24f);
    }
    Row->CreateMeshSection_LinearColor(0, V, Idx, Nrm, UV, Col, Tan, false);
    const FString PinPath = FString::Printf(TEXT("/Game/Materials/MSlot_%s.MSlot_%s"), Slot, Slot);
    UMaterialInterface* Mat = LoadObject<UMaterialInterface>(nullptr, *PinPath);
    if (!Mat)
    {
        Row->DestroyComponent();
        return nullptr;
    }
    Row->SetMaterial(0, Mat);
    Row->RegisterComponent();
    return Row;
}

static UProceduralMeshComponent* MakePadGrid(AActor* Owner, USceneComponent* Root, const FVector& Center, int32 CountX, int32 CountY, float Pitch, const FVector& PadSize, const TCHAR* Slot)
{
    if (CountX < 1 || CountY < 1 || PadSize.GetAbs().GetMax() < 0.01) { return nullptr; }
    UProceduralMeshComponent* Grid = NewObject<UProceduralMeshComponent>(Owner);
    Grid->SetCanEverAffectNavigation(false);
    Grid->SetupAttachment(Root);
    Grid->SetCollisionEnabled(ECollisionEnabled::NoCollision);
    TArray<FVector> V;
    TArray<int32> Idx;
    TArray<FVector> Nrm;
    TArray<FVector2D> UV;
    TArray<FLinearColor> Col;
    TArray<FProcMeshTangent> Tan;
    const FVector Hx(PadSize.X * 0.5f, 0.f, 0.f);
    const FVector Hy(0.f, PadSize.Y * 0.5f, 0.f);
    const FVector Hz(0.f, 0.f, PadSize.Z * 0.5f);
    const float SpanX = (CountX - 1) * Pitch;
    const float SpanY = (CountY - 1) * Pitch;
    for (int32 iy = 0; iy < CountY; ++iy)
    {
        for (int32 ix = 0; ix < CountX; ++ix)
        {
            const FVector O = Center + FVector(ix * Pitch - SpanX * 0.5f, iy * Pitch - SpanY * 0.5f, 0.f);
            const FVector Q0 = O - Hx - Hy - Hz;
            const FVector Q1 = O + Hx - Hy - Hz;
            const FVector Q2 = O + Hx + Hy - Hz;
            const FVector Q3 = O - Hx + Hy - Hz;
            const FVector Q4 = O - Hx - Hy + Hz;
            const FVector Q5 = O + Hx - Hy + Hz;
            const FVector Q6 = O + Hx + Hy + Hz;
            const FVector Q7 = O - Hx + Hy + Hz;
            AddFace(V, Idx, Nrm, UV, Col, Tan, Q4, Q5, Q6, Q7, FLinearColor::White);
            AddFace(V, Idx, Nrm, UV, Col, Tan, Q0, Q3, Q2, Q1, FLinearColor::White);
            AddFace(V, Idx, Nrm, UV, Col, Tan, Q0, Q1, Q5, Q4, FLinearColor::White);
            AddFace(V, Idx, Nrm, UV, Col, Tan, Q3, Q7, Q6, Q2, FLinearColor::White);
            AddFace(V, Idx, Nrm, UV, Col, Tan, Q1, Q2, Q6, Q5, FLinearColor::White);
            AddFace(V, Idx, Nrm, UV, Col, Tan, Q0, Q4, Q7, Q3, FLinearColor::White);
        }
    }
    Grid->CreateMeshSection_LinearColor(0, V, Idx, Nrm, UV, Col, Tan, false);
    const FString PadPath = FString::Printf(TEXT("/Game/Materials/MSlot_%s.MSlot_%s"), Slot, Slot);
    UMaterialInterface* Mat = LoadObject<UMaterialInterface>(nullptr, *PadPath);
    if (!Mat)
    {
        Grid->DestroyComponent();
        return nullptr;
    }
    Grid->SetMaterial(0, Mat);
    Grid->RegisterComponent();
    return Grid;
}

void AMbgenBoardActor::AddBox(const FVector& CenterIn, const FVector& SizeCm, const FLinearColor& Color, const FString& MaterialName, const FString& PartId, const FString& PartRole, int32 YawQ)
{
    UProceduralMeshComponent* Mesh = NewObject<UProceduralMeshComponent>(this);
    Mesh->SetCanEverAffectNavigation(false);
    Mesh->SetupAttachment(RootComponent);
    FVector CenterCm = CenterIn;
    const FVector H = SizeCm * 0.5f;
    const FString& Kind = PartRole.IsEmpty() ? PartId : PartRole;
    TArray<FVector> V;
    TArray<int32> I;
    TArray<FVector> N;
    TArray<FVector2D> UV;
    TArray<FLinearColor> C;
    TArray<FProcMeshTangent> T;
    const float Chamfer = FMath::Clamp(FMath::Min3(H.X, H.Y, H.Z) * 0.28f, 0.03f, 0.14f);
    const bool bBevel = Kind != TEXT("pcb") && Kind != TEXT("shield") && Kind != TEXT("rtc_battery") && Kind != TEXT("hdmi") && Kind != TEXT("dp") && Kind != TEXT("pcie_cem")
        && Chamfer < FMath::Min3(H.X, H.Y, H.Z) * 0.75f
        && !(MaterialName == TEXT("ceramic") && SizeCm.X < 0.50f && SizeCm.Y < 0.50f);
    if (Kind == TEXT("hdmi") || Kind == TEXT("dp"))
    {
        const FVector O = CenterCm;
        const float xb = H.X * 0.72f;
        const float xt = H.X;
        AddFace(V, I, N, UV, C, T, O+FVector(-xb,-H.Y,-H.Z), O+FVector(-xb, H.Y,-H.Z), O+FVector( xb, H.Y,-H.Z), O+FVector( xb,-H.Y,-H.Z), Color);
        AddFace(V, I, N, UV, C, T, O+FVector(-xt,-H.Y, H.Z), O+FVector( xt,-H.Y, H.Z), O+FVector( xt, H.Y, H.Z), O+FVector(-xt, H.Y, H.Z), Color);
        AddFace(V, I, N, UV, C, T, O+FVector(-xb,-H.Y,-H.Z), O+FVector( xb,-H.Y,-H.Z), O+FVector( xt,-H.Y, H.Z), O+FVector(-xt,-H.Y, H.Z), Color);
        AddFace(V, I, N, UV, C, T, O+FVector(-xb, H.Y,-H.Z), O+FVector(-xt, H.Y, H.Z), O+FVector( xt, H.Y, H.Z), O+FVector( xb, H.Y,-H.Z), Color);
        AddFace(V, I, N, UV, C, T, O+FVector( xb,-H.Y,-H.Z), O+FVector( xb, H.Y,-H.Z), O+FVector( xt, H.Y, H.Z), O+FVector( xt,-H.Y, H.Z), Color);
        AddFace(V, I, N, UV, C, T, O+FVector(-xb,-H.Y,-H.Z), O+FVector(-xt,-H.Y, H.Z), O+FVector(-xt, H.Y, H.Z), O+FVector(-xb, H.Y,-H.Z), Color);
    }
    else if (Kind == TEXT("rtc_battery"))
    {
        const float Radius = H.X / 0.9238795f;
        FVector Bot[8];
        FVector Top[8];
        for (int32 k = 0; k < 8; ++k)
        {
            const float Ang = FMath::DegreesToRadians(22.5f + 45.f * k);
            const FVector Rim(Radius * FMath::Cos(Ang), Radius * FMath::Sin(Ang), 0.f);
            Bot[k] = CenterCm + Rim + FVector(0.f, 0.f, -H.Z);
            Top[k] = CenterCm + Rim + FVector(0.f, 0.f, H.Z);
        }
        const FVector BotMid = CenterCm + FVector(0.f, 0.f, -H.Z);
        const FVector TopMid = CenterCm + FVector(0.f, 0.f, H.Z);
        for (int32 k = 0; k < 8; ++k)
        {
            const int32 n = (k + 1) % 8;
            const int32 Base = V.Num();
            V.Add(BotMid); V.Add(Bot[n]); V.Add(Bot[k]);
            const FVector Down = FVector::UpVector * -1.f;
            for (int32 t = 0; t < 3; ++t) { C.Add(Color); N.Add(Down); UV.Add(FVector2D(0.5f, 0.5f)); T.Add(FProcMeshTangent(FVector(1.f, 0.f, 0.f), false)); }
            I.Append({Base, Base + 1, Base + 2});
            const int32 Cap = V.Num();
            V.Add(TopMid); V.Add(Top[k]); V.Add(Top[n]);
            for (int32 t = 0; t < 3; ++t) { C.Add(Color); N.Add(FVector::UpVector); UV.Add(FVector2D(0.5f, 0.5f)); T.Add(FProcMeshTangent(FVector(1.f, 0.f, 0.f), false)); }
            I.Append({Cap, Cap + 1, Cap + 2});
            AddFace(V, I, N, UV, C, T, Bot[k], Bot[n], Top[n], Top[k], Color);
        }
    }
    else if (!bBevel)
    {
        const FVector Corners[8] = {
            CenterCm + FVector(-H.X,-H.Y,-H.Z), CenterCm + FVector(H.X,-H.Y,-H.Z),
            CenterCm + FVector(H.X,H.Y,-H.Z), CenterCm + FVector(-H.X,H.Y,-H.Z),
            CenterCm + FVector(-H.X,-H.Y,H.Z), CenterCm + FVector(H.X,-H.Y,H.Z),
            CenterCm + FVector(H.X,H.Y,H.Z), CenterCm + FVector(-H.X,H.Y,H.Z)
        };
        const int32 Faces[6][4] = {{4,5,6,7},{0,3,2,1},{3,7,6,2},{0,1,5,4},{1,2,6,5},{0,4,7,3}};
        for (int32 f = 0; f < 6; ++f)
        {
            const int32 b = V.Num();
            const FVector EdgeU = Corners[Faces[f][1]] - Corners[Faces[f][0]];
            const FVector FaceN = FVector::CrossProduct(EdgeU, Corners[Faces[f][2]] - Corners[Faces[f][0]]).GetSafeNormal();
            const FProcMeshTangent FaceTan(EdgeU.GetSafeNormal(), false);
            for (int32 k = 0; k < 4; ++k) { V.Add(Corners[Faces[f][k]]); C.Add(Color); UV.Add(FVector2D(k==1||k==2, k>=2)); N.Add(FaceN); T.Add(FaceTan); }
            I.Append({b, b+1, b+2, b, b+2, b+3});
        }
    }
    else
    {
        const FVector O = CenterCm;
        const float ix = H.X - Chamfer;
        const float iy = H.Y - Chamfer;
        const float zt = H.Z;
        const float ze = H.Z - Chamfer;
        const float zb = -H.Z;
        AddFace(V, I, N, UV, C, T, O+FVector(-H.X,-H.Y,zb), O+FVector(-H.X, H.Y,zb), O+FVector( H.X, H.Y,zb), O+FVector( H.X,-H.Y,zb), Color);
        AddFace(V, I, N, UV, C, T, O+FVector(-H.X,-H.Y,zb), O+FVector( H.X,-H.Y,zb), O+FVector( H.X,-H.Y,ze), O+FVector(-H.X,-H.Y,ze), Color);
        AddFace(V, I, N, UV, C, T, O+FVector(-H.X, H.Y,zb), O+FVector(-H.X, H.Y,ze), O+FVector( H.X, H.Y,ze), O+FVector( H.X, H.Y,zb), Color);
        AddFace(V, I, N, UV, C, T, O+FVector( H.X,-H.Y,zb), O+FVector( H.X, H.Y,zb), O+FVector( H.X, H.Y,ze), O+FVector( H.X,-H.Y,ze), Color);
        AddFace(V, I, N, UV, C, T, O+FVector(-H.X,-H.Y,zb), O+FVector(-H.X,-H.Y,ze), O+FVector(-H.X, H.Y,ze), O+FVector(-H.X, H.Y,zb), Color);
        AddFace(V, I, N, UV, C, T, O+FVector(-ix,-iy,zt), O+FVector( ix,-iy,zt), O+FVector( ix, iy,zt), O+FVector(-ix, iy,zt), Color);
        AddFace(V, I, N, UV, C, T, O+FVector(-H.X,-H.Y,ze), O+FVector( H.X,-H.Y,ze), O+FVector( ix,-iy,zt), O+FVector(-ix,-iy,zt), Color);
        AddFace(V, I, N, UV, C, T, O+FVector( H.X, H.Y,ze), O+FVector(-H.X, H.Y,ze), O+FVector(-ix, iy,zt), O+FVector( ix, iy,zt), Color);
        AddFace(V, I, N, UV, C, T, O+FVector( H.X,-H.Y,ze), O+FVector( H.X, H.Y,ze), O+FVector( ix, iy,zt), O+FVector( ix,-iy,zt), Color);
        AddFace(V, I, N, UV, C, T, O+FVector(-H.X, H.Y,ze), O+FVector(-H.X,-H.Y,ze), O+FVector(-ix,-iy,zt), O+FVector(-ix, iy,zt), Color);
    }
    for (FVector& P : V) { P -= CenterCm; }
    Mesh->CreateMeshSection_LinearColor(0, V, I, N, UV, C, T, true);
    Mesh->SetRelativeLocation(CenterCm);
    Mesh->SetRelativeRotation(FRotator(0.f, float(YawQ) * 90.f, 0.f));
    Mesh->SetCollisionEnabled(ECollisionEnabled::QueryOnly);
    Mesh->SetCollisionResponseToChannel(ECC_Visibility, ECR_Block);
    const FString BodySlot = Kind == TEXT("pcie_slot") ? FString(TEXT("plastic")) : MaterialName;
    const FString Path = FString::Printf(TEXT("/Game/Materials/MSlot_%s.MSlot_%s"), *BodySlot, *BodySlot);
    if (UMaterialInterface* Mat = LoadObject<UMaterialInterface>(nullptr, *Path))
    {
        Mesh->SetMaterial(0, Mat);
    }
    Mesh->ComponentTags.Add(FName(*PartId));
    Mesh->RegisterComponent();
    Sections.Add(Mesh);
    auto Tag = [PartId](UProceduralMeshComponent* Comp)
    {
        if (Comp) { Comp->ComponentTags.Add(FName(*PartId)); }
    };
    auto PlaceWell = [this, Tag, Mesh, CenterCm](const FVector& WellCenter, const FVector& WellSize, const TCHAR* Slot)
    {
        if (UProceduralMeshComponent* Well = MakeWell(this, Mesh, WellCenter - CenterCm, WellSize, Slot))
        {
            Tag(Well);
            Sections.Add(Well);
        }
    };
    auto PlacePins = [this, Tag, Mesh, CenterCm](const FVector& PinCenter, const FVector& Along, int32 Count, float Pitch, const FVector& PinSize, const TCHAR* SlotName, const FVector& HeadLean)
    {
        if (UProceduralMeshComponent* Row = MakePinRow(this, Mesh, PinCenter - CenterCm, Along, Count, Pitch, PinSize, SlotName, HeadLean))
        {
            Tag(Row);
            Sections.Add(Row);
        }
    };
    auto PlacePads = [this, Tag, Mesh, CenterCm](const FVector& GridCenter, int32 CountX, int32 CountY, float Pitch, const FVector& PadSize, const TCHAR* SlotName)
    {
        if (UProceduralMeshComponent* Grid = MakePadGrid(this, Mesh, GridCenter - CenterCm, CountX, CountY, Pitch, PadSize, SlotName))
        {
            Tag(Grid);
            Sections.Add(Grid);
        }
    };
    if (Kind == TEXT("pcb"))
    {
        if (FMath::IsNearlyEqual(SizeCm.X, 17.0f, 0.6f) && FMath::IsNearlyEqual(SizeCm.Y, 17.0f, 0.6f))
        {
            // Mini-ITX holes C, F, H, J. Centimetres from the front-left corner.
            const FVector Origin(CenterCm.X - H.X, CenterCm.Y - H.Y, CenterCm.Z);
            const FVector Marks[4] = {
                FVector(0.635f, 15.984f, 0.f),
                FVector(16.383f, 13.698f, 0.f),
                FVector(0.635f, 0.490f, 0.f),
                FVector(16.383f, 0.490f, 0.f)
            };
            for (const FVector& Mark : Marks)
            {
                const FVector At = Origin + Mark;
                PlaceWell(At + FVector(0.f, 0.f, H.Z + 0.02f), FVector(0.62f, 0.62f, 0.06f), TEXT("gold"));
                PlaceWell(At + FVector(0.f, 0.f, H.Z + 0.06f), FVector(0.36f, 0.36f, 0.08f), TEXT("cavity"));
                PlaceWell(At + FVector(0.f, 0.f, H.Z + 0.10f), FVector(0.18f, 0.18f, 0.06f), TEXT("metal"));
            }
        }
        return;
    }
    if (Kind == TEXT("shield"))
    {
        Mesh->SetVisibility(false);
        Mesh->SetCollisionEnabled(ECollisionEnabled::NoCollision);
        if (SizeCm.GetAbs().GetMax() < 0.05)
        {
            Mesh->DestroyComponent();
            Sections.Remove(Mesh);
            return;
        }
        PlaceWell(CenterCm + FVector(0.f, -(H.Y + 0.22f), H.Z - 0.05f), FVector(SizeCm.X * 0.98f, 0.55f, 0.12f), TEXT("metal"));
        const float Yt = SizeCm.Y;
        const float ZTop = CenterCm.Z + H.Z;
        const float ZBot = CenterCm.Z - H.Z;
        const float XLft = CenterCm.X - H.X;
        const float XRgt = CenterCm.X + H.X;
        struct FShieldCut { float X; float W; float H; float Z; };
        TArray<FShieldCut> Cuts;
        for (const TPair<FString, FString>& Pair : BodyRoles)
        {
            const FVector* JackC = BodyCentersCm.Find(Pair.Key);
            const FVector* JackS = BodySizesCm.Find(Pair.Key);
            if (!JackC || !JackS) { continue; }
            float W = 0.f;
            float Ht = 0.f;
            if (Pair.Value == TEXT("usb_stack")) { W = JackS->X * 0.84f; Ht = 0.52f; }
            else if (Pair.Value == TEXT("gbe_magjack")) { W = JackS->X; Ht = JackS->Z * 0.964f; }
            else if (Pair.Value == TEXT("hdmi") || Pair.Value == TEXT("dp")) { W = JackS->X * 0.933f; Ht = 0.48f; }
            else if (Pair.Value == TEXT("dc_jack")) { W = JackS->X * 0.70f; Ht = JackS->Z * 0.70f; }
            else { continue; }
            Cuts.Add({(float)JackC->X, W, Ht, (float)JackC->Z});
        }
        Cuts.Sort([](const FShieldCut& A, const FShieldCut& B) { return A.X < B.X; });
        if (Cuts.Num() == 0)
        {
            PlaceWell(CenterCm, FVector(SizeCm.X, Yt, SizeCm.Z), TEXT("metal"));
            return;
        }
        float BandTop = ZBot;
        float BandBot = ZTop;
        for (const FShieldCut& Cut : Cuts)
        {
            BandTop = FMath::Max(BandTop, Cut.Z + Cut.H * 0.5f);
            BandBot = FMath::Min(BandBot, Cut.Z - Cut.H * 0.5f);
        }
        PlaceWell(FVector(CenterCm.X, CenterCm.Y, (BandTop + ZTop) * 0.5f), FVector(SizeCm.X, Yt, FMath::Max(0.12f, ZTop - BandTop)), TEXT("metal"));
        PlaceWell(FVector(CenterCm.X, CenterCm.Y, (ZBot + BandBot) * 0.5f), FVector(SizeCm.X, Yt, FMath::Max(0.12f, BandBot - ZBot)), TEXT("metal"));
        float Cursor = XLft;
        for (const FShieldCut& Cut : Cuts)
        {
            const float L = Cut.X - Cut.W * 0.5f;
            const float R = Cut.X + Cut.W * 0.5f;
            if (L > Cursor + 0.04f)
            {
                PlaceWell(FVector((Cursor + L) * 0.5f, CenterCm.Y, (BandBot + BandTop) * 0.5f), FVector(L - Cursor, Yt, BandTop - BandBot), TEXT("metal"));
            }
            Cursor = R;
        }
        if (XRgt > Cursor + 0.04f)
        {
            PlaceWell(FVector((Cursor + XRgt) * 0.5f, CenterCm.Y, (BandBot + BandTop) * 0.5f), FVector(XRgt - Cursor, Yt, BandTop - BandBot), TEXT("metal"));
        }
        return;
    }
    if (Kind == TEXT("usb_stack") || Kind == TEXT("hdmi") || Kind == TEXT("gbe_magjack") || Kind == TEXT("dp") || Kind == TEXT("dc_jack"))
    {
        PlaceWell(CenterCm + FVector(0.f, 0.f, H.Z + 0.14f), FVector(SizeCm.X * 0.78f, SizeCm.Y * 0.62f, 0.36f), TEXT("cavity"));
        if (Kind == TEXT("usb_stack"))
        {
            PlaceWell(CenterCm + FVector(0.f,  H.Y + 0.04f, 0.f), FVector(SizeCm.X * 0.84f, 0.16f, 0.52f), TEXT("cavity"));
            PlaceWell(CenterCm + FVector(0.f, -(H.Y + 0.04f), 0.f), FVector(SizeCm.X * 0.84f, 0.16f, 0.52f), TEXT("cavity"));
        }
        else
        {
            PlaceWell(CenterCm + FVector(0.f,  H.Y + 0.04f, 0.f), FVector(SizeCm.X * 0.7f, 0.16f, SizeCm.Z * 0.58f), TEXT("cavity"));
            PlaceWell(CenterCm + FVector(0.f, -(H.Y + 0.04f), 0.f), FVector(SizeCm.X * 0.7f, 0.16f, SizeCm.Z * 0.58f), TEXT("cavity"));
        }
        if (Kind == TEXT("hdmi") || Kind == TEXT("gbe_magjack") || Kind == TEXT("dp"))
        {
            const int32 Contacts = FMath::Max(1, FMath::FloorToInt(SizeCm.X * 0.70f / 0.1f));
            const FVector JackPin(0.08f, 0.032f, 0.05f);
            const FVector MouthPin(0.10f, 0.034f, 0.08f);
            PlacePins(CenterCm + FVector(0.f, -0.45f, H.Z + 0.36f), FVector(1.f, 0.f, 0.f), Contacts, 0.1f, JackPin, TEXT("pin"), FVector(0.f, -0.014f, 0.008f));
            PlacePins(CenterCm + FVector(0.f,  H.Y + 0.16f, 0.0f), FVector(1.f, 0.f, 0.f), Contacts, 0.1f, MouthPin, TEXT("pin"), FVector(0.f,  0.024f, 0.010f));
            PlacePins(CenterCm + FVector(0.f, -(H.Y + 0.16f), 0.0f), FVector(1.f, 0.f, 0.f), Contacts, 0.1f, MouthPin, TEXT("pin"), FVector(0.f, -0.024f, 0.010f));
        }
    }
    else if (Kind == TEXT("sata"))
    {
        PlaceWell(CenterCm + FVector(0.f, 0.f, H.Z + 0.06f), FVector(SizeCm.X * 0.5f, SizeCm.Y * 0.4f, 0.16f), TEXT("cavity"));
        PlaceWell(CenterCm + FVector(-(H.X + 0.22f), 0.12f, 0.f), FVector(0.5f, SizeCm.Y * 0.62f, SizeCm.Z * 0.8f), TEXT("metal"));
        const FVector SataPin(0.07f, 0.030f, 0.05f);
        PlacePins(CenterCm + FVector(-0.55f, -0.40f, H.Z + 0.18f), FVector(0.f, 1.f, 0.f), 6, 0.1f, SataPin, TEXT("pin"), FVector(-0.012f, 0.f, 0.008f));
        PlacePins(CenterCm + FVector(-0.55f,  0.35f, H.Z + 0.18f), FVector(0.f, 1.f, 0.f), 7, 0.1f, SataPin, TEXT("pin"), FVector(-0.012f, 0.f, 0.008f));
        PlaceWell(CenterCm + FVector(-0.55f, 0.0f, H.Z + 0.14f), FVector(0.08f, 0.14f, 0.10f), TEXT("plastic"));
    }
    else if (Kind == TEXT("pcie_slot"))
    {
        PlaceWell(CenterCm + FVector(0.f, 0.f, H.Z + 0.06f), FVector(SizeCm.X * 0.88f, SizeCm.Y * 0.22f, 0.18f), TEXT("cavity"));
        const FVector Spring(0.11f, 0.034f, 0.12f);
        PlacePins(CenterCm + FVector(0.f, -0.18f, H.Z + 0.22f), FVector(1.f, 0.f, 0.f), 17, 0.1f, Spring, TEXT("pin"), FVector(0.f, 0.028f, 0.012f));
        PlacePins(CenterCm + FVector(0.f, 0.18f, H.Z + 0.22f), FVector(1.f, 0.f, 0.f), 17, 0.1f, Spring, TEXT("pin"), FVector(0.f, -0.028f, 0.012f));
        PlaceWell(CenterCm + FVector(-(H.X - 0.22f), 0.f, H.Z * 0.35f), FVector(0.42f, SizeCm.Y * 0.7f, SizeCm.Z * 0.55f), TEXT("plastic"));
        PlaceWell(CenterCm + FVector(H.X + 0.10f, 0.f, H.Z * 0.15f), FVector(0.22f, SizeCm.Y * 1.35f, SizeCm.Z * 0.85f), TEXT("plastic"));
        PlaceWell(CenterCm + FVector(H.X + 0.10f, 0.f, H.Z + 0.08f), FVector(0.16f, SizeCm.Y * 0.55f, 0.14f), TEXT("plastic"));
    }
    else if (Kind == TEXT("pcie_cem"))
    {
        PlaceWell(CenterCm + FVector(0.f, H.Y, 0.f), FVector(SizeCm.X * 0.98f, 0.04f, SizeCm.Z * 0.90f), TEXT("pin"));
        PlaceWell(CenterCm + FVector(H.X * 0.22f, H.Y + 0.02f, 0.f), FVector(0.18f, 0.08f, SizeCm.Z * 1.10f), TEXT("plastic"));
    }
    else if (Kind == TEXT("dimm") || Kind == TEXT("sodimm"))
    {
        PlaceWell(CenterCm + FVector(0.f, 0.f, H.Z + 0.08f), FVector(SizeCm.X * 0.38f, SizeCm.Y * 0.92f, 0.22f), TEXT("cavity"));
        const FVector Latch(SizeCm.X * 1.15f, 0.38f, SizeCm.Z * 0.28f);
        PlaceWell(CenterCm + FVector(0.f, H.Y - 0.15f, H.Z * 0.45f), Latch, TEXT("plastic"));
        PlaceWell(CenterCm + FVector(0.f, -(H.Y - 0.15f), H.Z * 0.45f), Latch, TEXT("plastic"));
        PlaceWell(CenterCm + FVector(0.f, H.Y * 0.28f, H.Z + 0.02f), FVector(SizeCm.X * 0.55f, 0.22f, 0.14f), TEXT("plastic"));
        const FVector DimmSpring(0.10f, 0.034f, 0.09f);
        const int32 Contacts = FMath::Max(1, FMath::FloorToInt(SizeCm.Y * 0.78f / 0.1f));
        PlacePins(CenterCm + FVector( 0.20f, 0.f, H.Z + 0.22f), FVector(0.f, 1.f, 0.f), Contacts, 0.1f, DimmSpring, TEXT("pin"), FVector(-0.022f, 0.f, 0.012f));
        PlacePins(CenterCm + FVector(-0.20f, 0.f, H.Z + 0.22f), FVector(0.f, 1.f, 0.f), Contacts, 0.1f, DimmSpring, TEXT("pin"), FVector( 0.022f, 0.f, 0.012f));
    }
    else if (Kind == TEXT("socket"))
    {
        PlaceWell(CenterCm + FVector(0.f, 0.f, H.Z + 0.08f), FVector(SizeCm.X * 0.86f, SizeCm.Y * 0.86f, 0.24f), TEXT("cavity"));
        const float Band = 0.16f;
        const float Outer = SizeCm.X * 0.94f;
        const float Inner = SizeCm.X * 0.70f;
        const float LandZ = H.Z + 0.03f;
        PlaceWell(CenterCm + FVector(0.f, Outer * 0.5f - Band, LandZ), FVector(Outer, Band, 0.06f), TEXT("metal"));
        PlaceWell(CenterCm + FVector(0.f, -(Outer * 0.5f - Band), LandZ), FVector(Outer, Band, 0.06f), TEXT("metal"));
        PlaceWell(CenterCm + FVector(Outer * 0.5f - Band, 0.f, LandZ), FVector(Band, Inner, 0.06f), TEXT("metal"));
        PlaceWell(CenterCm + FVector(-(Outer * 0.5f - Band), 0.f, LandZ), FVector(Band, Inner, 0.06f), TEXT("metal"));
        const float LandPitch = 0.1f;
        const int32 Nx = FMath::Max(1, FMath::FloorToInt(SizeCm.X * 0.58f / LandPitch));
        const int32 Ny = FMath::Max(1, FMath::FloorToInt(SizeCm.Y * 0.58f / LandPitch));
        PlacePads(CenterCm + FVector(0.f, 0.f, H.Z + 0.22f), Nx, Ny, LandPitch, FVector(0.05f, 0.05f, 0.016f), TEXT("pin"));
        PlaceWell(CenterCm + FVector(H.X + 0.12f, 0.f, H.Z * 0.20f), FVector(0.28f, SizeCm.Y * 0.58f, SizeCm.Z * 0.90f), TEXT("plastic"));
        PlaceWell(CenterCm + FVector(H.X + 0.12f, 0.f, H.Z + 0.10f), FVector(0.20f, SizeCm.Y * 0.22f, 0.12f), TEXT("plastic"));
    }
    else if (Kind == TEXT("rtc_battery"))
    {
        const float Post = 0.22f;
        const FVector PostSize(Post, Post, SizeCm.Z * 0.9f);
        const float Ox = H.X - Post * 0.35f;
        const float Oy = H.Y - Post * 0.35f;
        PlaceWell(CenterCm + FVector( Ox,  Oy, H.Z * 0.15f), PostSize, TEXT("plastic"));
        PlaceWell(CenterCm + FVector( Ox, -Oy, H.Z * 0.15f), PostSize, TEXT("plastic"));
        PlaceWell(CenterCm + FVector(-Ox,  Oy, H.Z * 0.15f), PostSize, TEXT("plastic"));
        PlaceWell(CenterCm + FVector(-Ox, -Oy, H.Z * 0.15f), PostSize, TEXT("plastic"));
        PlaceWell(CenterCm + FVector(0.f, 0.f, H.Z + 0.04f), FVector(SizeCm.X * 0.50f, 0.14f, 0.03f), TEXT("metal"));
        const int32 Contacts = FMath::Max(1, FMath::FloorToInt(SizeCm.X * 0.40f / 0.1f));
        PlacePins(CenterCm + FVector(0.f, 0.f, H.Z + 0.08f), FVector(1.f, 0.f, 0.f), Contacts, 0.1f, FVector(0.07f, 0.040f, 0.05f), TEXT("pin"), FVector(0.f, 0.f, 0.008f));
    }
    else if (Kind == TEXT("front_panel"))
    {
        const int32 Contacts = FMath::Max(1, FMath::FloorToInt(SizeCm.X * 0.70f / 0.1f));
        const FVector Post(0.05f, 0.028f, 0.22f);
        PlacePins(CenterCm + FVector(0.f,  H.Y * 0.38f, H.Z + 0.16f), FVector(1.f, 0.f, 0.f), Contacts, 0.1f, Post, TEXT("pin"), FVector(0.f, 0.f, 0.010f));
        PlacePins(CenterCm + FVector(0.f, -H.Y * 0.38f, H.Z + 0.16f), FVector(1.f, 0.f, 0.f), Contacts, 0.1f, Post, TEXT("pin"), FVector(0.f, 0.f, 0.010f));
    }
    else if (Kind == TEXT("nvme_m2") || Kind == TEXT("wifi_m2"))
    {
        const FVector Finger(0.07f, 0.055f, 0.028f);
        PlacePins(CenterCm + FVector(-0.55f, H.Y,  H.Z * 0.42f), FVector(1.f, 0.f, 0.f), 8, 0.1f, Finger, TEXT("pin"), FVector(0.f, 0.020f, 0.0f));
        PlacePins(CenterCm + FVector(-0.55f, H.Y, -H.Z * 0.42f), FVector(1.f, 0.f, 0.f), 8, 0.1f, Finger, TEXT("pin"), FVector(0.f, 0.020f, 0.0f));
        PlacePins(CenterCm + FVector( 0.50f, H.Y,  H.Z * 0.42f), FVector(1.f, 0.f, 0.f), 7, 0.1f, Finger, TEXT("pin"), FVector(0.f, 0.020f, 0.0f));
        PlacePins(CenterCm + FVector( 0.50f, H.Y, -H.Z * 0.42f), FVector(1.f, 0.f, 0.f), 7, 0.1f, Finger, TEXT("pin"), FVector(0.f, 0.020f, 0.0f));
        PlaceWell(CenterCm + FVector(0.08f, H.Y + 0.02f, 0.f), FVector(0.18f, 0.10f, SizeCm.Z * 1.15f), TEXT("plastic"));
        PlaceWell(CenterCm + FVector(0.f, H.Y + 0.12f, -H.Z + 0.08f), FVector(SizeCm.X * 0.98f, 0.24f, 0.22f), TEXT("plastic"));
        PlaceWell(CenterCm + FVector(0.f, -H.Y * 0.55f, H.Z + 0.05f), FVector(0.22f, 0.22f, 0.08f), TEXT("metal"));
        PlaceWell(CenterCm + FVector(0.f, -H.Y * 0.22f, H.Z + 0.08f), FVector(0.95f, 1.15f, 0.12f), TEXT("ceramic"));
        PlaceWell(CenterCm + FVector(0.f,  H.Y * 0.12f, H.Z + 0.08f), FVector(1.05f, 1.45f, 0.10f), TEXT("ceramic"));
        PlaceWell(CenterCm + FVector(0.f,  H.Y * 0.42f, H.Z + 0.08f), FVector(0.95f, 1.25f, 0.10f), TEXT("ceramic"));
        const FVector NvmeLead(0.04f, 0.026f, 0.07f);
        auto PlaceNvmeLeads = [&](const FVector& Off, const FVector& S)
        {
            const FVector Pkg = CenterCm + Off;
            const FVector HS = S * 0.5f;
            const int32 LeadN = FMath::Max(1, FMath::FloorToInt(S.Y * 0.86f / 0.1f));
            PlacePins(Pkg + FVector( HS.X, 0.f, -HS.Z * 0.20f), FVector(0.f, 1.f, 0.f), LeadN, 0.1f, NvmeLead, TEXT("pin"), FVector( 0.012f, 0.f, 0.004f));
            PlacePins(Pkg + FVector(-HS.X, 0.f, -HS.Z * 0.20f), FVector(0.f, 1.f, 0.f), LeadN, 0.1f, NvmeLead, TEXT("pin"), FVector(-0.012f, 0.f, 0.004f));
        };
        PlaceNvmeLeads(FVector(0.f, -H.Y * 0.22f, H.Z + 0.08f), FVector(0.95f, 1.15f, 0.12f));
        PlaceNvmeLeads(FVector(0.f,  H.Y * 0.12f, H.Z + 0.08f), FVector(1.05f, 1.45f, 0.10f));
        PlaceNvmeLeads(FVector(0.f,  H.Y * 0.42f, H.Z + 0.08f), FVector(0.95f, 1.25f, 0.10f));
    }
    if (Kind == TEXT("crystal"))
    {
        PlaceWell(CenterCm + FVector(0.f, 0.f, H.Z * 0.2f), FVector(SizeCm.X * 0.88f, SizeCm.Y * 0.88f, SizeCm.Z * 0.62f), TEXT("metal"));
        PlacePins(CenterCm + FVector(0.f, 0.f, -H.Z * 0.35f), FVector(1.f, 0.f, 0.f), 2, SizeCm.X * 0.55f, FVector(0.08f, 0.06f, 0.04f), TEXT("pin"), FVector(0.f, 0.f, 0.006f));
    }
    if (Kind == TEXT("usb_stack"))
    {
        PlaceWell(CenterCm + FVector(0.f, 0.f, H.Z + 0.06f), FVector(SizeCm.X * 0.42f, SizeCm.Y * 0.22f, 0.08f), TEXT("plastic"));
        const float Bezel = 0.10f;
        const float MouthW = SizeCm.X * 0.84f;
        const float MouthH = 0.52f;
        const float SideX = MouthW * 0.5f + Bezel * 0.5f;
        const float YFace[2] = { H.Y + 0.02f, -(H.Y + 0.02f) };
        for (float Yb : YFace)
        {
            PlaceWell(CenterCm + FVector(0.f, Yb,  MouthH * 0.5f + Bezel * 0.5f), FVector(SizeCm.X * 0.70f, 0.08f, Bezel), TEXT("metal"));
            PlaceWell(CenterCm + FVector(0.f, Yb, -(MouthH * 0.5f + Bezel * 0.5f)), FVector(SizeCm.X * 0.90f, 0.08f, Bezel), TEXT("metal"));
            PlaceWell(CenterCm + FVector( SideX, Yb, 0.f), FVector(Bezel, 0.08f, MouthH), TEXT("metal"));
            PlaceWell(CenterCm + FVector(-SideX, Yb, 0.f), FVector(Bezel, 0.08f, MouthH), TEXT("metal"));
            PlaceWell(CenterCm + FVector(0.f, Yb + FMath::Sign(Yb) * 0.14f, MouthH * 0.22f), FVector(MouthW * 0.62f, 0.10f, 0.16f), TEXT("plastic"));
        }
    }
    if (Kind == TEXT("hdmi") || Kind == TEXT("dp"))
    {
        const float Bezel = 0.08f;
        const float YFace[2] = { H.Y + 0.02f, -(H.Y + 0.02f) };
        for (float Yb : YFace)
        {
            PlaceWell(CenterCm + FVector(0.f, Yb,  H.Z * 0.70f), FVector(SizeCm.X * 0.92f, 0.08f, Bezel), TEXT("metal"));
            PlaceWell(CenterCm + FVector(0.f, Yb, -H.Z * 0.42f), FVector(SizeCm.X * 0.70f, 0.08f, Bezel), TEXT("metal"));
            PlaceWell(CenterCm + FVector( H.X * 0.78f, Yb, 0.14f), FVector(Bezel, 0.08f, SizeCm.Z * 0.68f), TEXT("metal"));
            PlaceWell(CenterCm + FVector(-H.X * 0.78f, Yb, 0.14f), FVector(Bezel, 0.08f, SizeCm.Z * 0.68f), TEXT("metal"));
        }
    }
    if (Kind == TEXT("gbe_magjack"))
    {
        const float YFace[2] = { H.Y + 0.02f, -(H.Y + 0.02f) };
        for (float Yb : YFace)
        {
            PlaceWell(CenterCm + FVector(0.f, Yb, H.Z * 0.50f), FVector(0.46f, 0.10f, 0.12f), TEXT("plastic"));
            PlaceWell(CenterCm + FVector(-0.68f, Yb, -0.52f), FVector(0.16f, 0.06f, 0.12f), TEXT("led_green"));
            PlaceWell(CenterCm + FVector( 0.68f, Yb, -0.52f), FVector(0.16f, 0.06f, 0.12f), TEXT("led_amber"));
        }
    }
    if (Kind == TEXT("dc_jack"))
    {
        PlaceWell(CenterCm + FVector(0.f, H.Y + 0.06f, 0.f), FVector(SizeCm.X * 0.62f, 0.22f, SizeCm.Z * 0.62f), TEXT("metal"));
        PlaceWell(CenterCm + FVector(0.f, H.Y + 0.16f, 0.f), FVector(SizeCm.X * 0.38f, 0.12f, SizeCm.Z * 0.38f), TEXT("cavity"));
    }
    if (Kind == TEXT("esd"))
    {
        PlaceWell(CenterCm + FVector(0.f, 0.f, H.Z + 0.04f), FVector(SizeCm.X * 0.70f, SizeCm.Y * 0.70f, 0.08f), TEXT("cavity"));
        const float Band = 0.04f;
        PlaceWell(CenterCm + FVector(0.f,  H.Y * 0.88f, H.Z + 0.02f), FVector(SizeCm.X * 0.94f, Band, Band), TEXT("metal"));
        PlaceWell(CenterCm + FVector(0.f, -H.Y * 0.88f, H.Z + 0.02f), FVector(SizeCm.X * 0.94f, Band, Band), TEXT("metal"));
        PlaceWell(CenterCm + FVector( H.X * 0.88f, 0.f, H.Z + 0.02f), FVector(Band, SizeCm.Y * 0.94f, Band), TEXT("metal"));
        PlaceWell(CenterCm + FVector(-H.X * 0.88f, 0.f, H.Z + 0.02f), FVector(Band, SizeCm.Y * 0.94f, Band), TEXT("metal"));
    }
    if (MaterialName == TEXT("ceramic") && Kind != TEXT("nvme_m2") && Kind != TEXT("wifi_m2") && SizeCm.X >= 0.70f && SizeCm.Y >= 0.70f)
    {
        const float Pitch = 0.1f;
        const FVector Lead(0.04f, 0.026f, 0.07f);
        const float LeadZ = -H.Z * 0.10f;
        if (SizeCm.X >= SizeCm.Y)
        {
            const int32 LeadN = FMath::Max(1, FMath::FloorToInt(SizeCm.X * 0.86f / Pitch));
            PlacePins(CenterCm + FVector(0.f,  H.Y, LeadZ), FVector(1.f, 0.f, 0.f), LeadN, Pitch, Lead, TEXT("pin"), FVector(0.f,  0.012f, 0.004f));
            PlacePins(CenterCm + FVector(0.f, -H.Y, LeadZ), FVector(1.f, 0.f, 0.f), LeadN, Pitch, Lead, TEXT("pin"), FVector(0.f, -0.012f, 0.004f));
        }
        else
        {
            const int32 LeadN = FMath::Max(1, FMath::FloorToInt(SizeCm.Y * 0.86f / Pitch));
            PlacePins(CenterCm + FVector( H.X, 0.f, LeadZ), FVector(0.f, 1.f, 0.f), LeadN, Pitch, Lead, TEXT("pin"), FVector( 0.012f, 0.f, 0.004f));
            PlacePins(CenterCm + FVector(-H.X, 0.f, LeadZ), FVector(0.f, 1.f, 0.f), LeadN, Pitch, Lead, TEXT("pin"), FVector(-0.012f, 0.f, 0.004f));
        }
    }
    if (MaterialName == TEXT("ceramic") && SizeCm.X < 0.50f && SizeCm.Y < 0.50f)
    {
        const float Cap = 0.05f;
        const float Wrap = FMath::Max(0.06f, SizeCm.X * 0.24f);
        const float Hy = SizeCm.Y * 0.98f;
        const float Hz = SizeCm.Z * 0.98f;
        PlaceWell(CenterCm + FVector( H.X, 0.f, 0.f), FVector(Cap, Hy, Hz), TEXT("pin"));
        PlaceWell(CenterCm + FVector(-H.X, 0.f, 0.f), FVector(Cap, Hy, Hz), TEXT("pin"));
        PlaceWell(CenterCm + FVector( H.X - Wrap * 0.5f, 0.f,  H.Z), FVector(Wrap, Hy, Cap), TEXT("pin"));
        PlaceWell(CenterCm + FVector(-H.X + Wrap * 0.5f, 0.f,  H.Z), FVector(Wrap, Hy, Cap), TEXT("pin"));
        PlaceWell(CenterCm + FVector( H.X - Wrap * 0.5f, 0.f, -H.Z), FVector(Wrap, Hy, Cap), TEXT("pin"));
        PlaceWell(CenterCm + FVector(-H.X + Wrap * 0.5f, 0.f, -H.Z), FVector(Wrap, Hy, Cap), TEXT("pin"));
        PlaceWell(CenterCm + FVector( H.X - Wrap * 0.5f,  H.Y, 0.f), FVector(Wrap, Cap, Hz), TEXT("pin"));
        PlaceWell(CenterCm + FVector(-H.X + Wrap * 0.5f,  H.Y, 0.f), FVector(Wrap, Cap, Hz), TEXT("pin"));
        PlaceWell(CenterCm + FVector( H.X - Wrap * 0.5f, -H.Y, 0.f), FVector(Wrap, Cap, Hz), TEXT("pin"));
        PlaceWell(CenterCm + FVector(-H.X + Wrap * 0.5f, -H.Y, 0.f), FVector(Wrap, Cap, Hz), TEXT("pin"));
    }
    const FString LabelPath = FString::Printf(TEXT("/Game/Materials/MLabel_%s.MLabel_%s"), *PartId, *PartId);
    UMaterialInterface* LabelMat = LoadObject<UMaterialInterface>(nullptr, *LabelPath);
    if (!LabelMat) { return; }
    if (FMath::Max(SizeCm.X, SizeCm.Y) < 0.50f) { return; }
    if (FMath::Max(SizeCm.X, SizeCm.Y) >= 5.0f && FMath::Min(SizeCm.X, SizeCm.Y) <= 1.2f) { return; }
    if (Kind == TEXT("nvme_m2") || Kind == TEXT("wifi_m2") || Kind == TEXT("socket") || Kind == TEXT("front_panel")
        || Kind == TEXT("spi_flash") || Kind == TEXT("rtc_battery") || Kind == TEXT("phy_gbe") || Kind == TEXT("pcie_cem")) { return; }
    UProceduralMeshComponent* Plate = NewObject<UProceduralMeshComponent>(this);
    Plate->SetCanEverAffectNavigation(false);
    Plate->SetupAttachment(RootComponent);
    Plate->SetCollisionEnabled(ECollisionEnabled::NoCollision);
    const float W = FMath::Clamp(PartId.Len() * 0.18f, 0.55f, FMath::Min(2.2f, FMath::Max(SizeCm.X, SizeCm.Y) * 1.15f));
    const float Hh = 0.18f;
    const FVector PlateBase = CenterCm + FVector(0.f, 0.f, H.Z + 0.08f);
    const FVector* Pcb = BodyCentersCm.Find(TEXT("pcb"));
    const FVector Eye = Pcb ? (*Pcb + FVector(-10.5f, -18.5f, 15.6f)) : (PlateBase + FVector(-4.f, -8.f, 10.f));
    FVector Away = PlateBase - Eye;
    Away.Z = 0.f;
    Away = Away.GetSafeNormal();
    if (Away.IsNearlyZero()) { Away = FVector(1.f, 1.f, 0.f).GetSafeNormal(); }
    const FVector Right = FVector::CrossProduct(FVector::UpVector, Away).GetSafeNormal();
    const FVector Up = FVector::UpVector * (Hh * 2.f);
    const FVector Face = -Away;
    TArray<FVector> PV;
    TArray<int32> PlateIdx;
    TArray<FVector> PN;
    TArray<FVector2D> PUV;
    TArray<FLinearColor> PC;
    TArray<FProcMeshTangent> PTan;
    const FVector PlateCorners[4] = {
        PlateBase + Right * (W * 0.5f) + Up,
        PlateBase - Right * (W * 0.5f) + Up,
        PlateBase - Right * (W * 0.5f),
        PlateBase + Right * (W * 0.5f)
    };
    for (int32 k = 0; k < 4; ++k)
    {
        PV.Add(PlateCorners[k]);
        PC.Add(FLinearColor::White);
        PN.Add(Face);
        PUV.Add(FVector2D(k == 0 || k == 3, k < 2));
    }
    PlateIdx.Append({0, 2, 1, 0, 3, 2});
    Plate->CreateMeshSection_LinearColor(0, PV, PlateIdx, PN, PUV, PC, PTan, false);
    Plate->SetMaterial(0, LabelMat);
    Plate->ComponentTags.Add(FName(*PartId));
    Plate->RegisterComponent();
    Sections.Add(Plate);
}

void AMbgenBoardActor::ProbeVisibility()
{
    const FVector* Pcb = BodyCentersCm.Find(TEXT("pcb"));
    const FVector Local = Pcb ? *Pcb : FVector::ZeroVector;
    const FVector Aim = GetActorTransform().TransformPosition(Local);
    const FVector Start = Aim + FVector(-36.5f, -60.5f, 36.f) * MbgenPreviewScale;
    const FVector Dir = (Aim - Start).GetSafeNormal();
    FHitResult Hit;
    const bool bHit = GetWorld() && GetWorld()->LineTraceSingleByChannel(
        Hit, Start, Start + Dir * (500.f * MbgenPreviewScale), ECC_Visibility, FCollisionQueryParams(SCENE_QUERY_STAT(MbgenProbe), false));
    if (bHit && Hit.GetComponent() && Hit.GetComponent()->ComponentTags.Num() > 0)
    {
        UE_LOG(LogTemp, Display, TEXT("mbgen probe hit %s"), *Hit.GetComponent()->ComponentTags[0].ToString());
    }
    else
    {
        UE_LOG(LogTemp, Warning, TEXT("mbgen probe missed"));
    }
    if (Sections.Num() > 0 && Sections[0])
    {
        UE_LOG(LogTemp, Display, TEXT("mbgen pcb bounds extent %s"), *Sections[0]->Bounds.BoxExtent.ToString());
    }
}

void AMbgenBoardActor::FrameViewport()
{
#if WITH_EDITOR
    if (!GEditor) { return; }
    const FVector* Pcb = BodyCentersCm.Find(TEXT("pcb"));
    const FVector* PcbSize = BodySizesCm.Find(TEXT("pcb"));
    if (!Pcb || !PcbSize) { return; }
    const FTransform Xform = GetActorTransform();
    const FVector Center = Xform.TransformPosition(*Pcb);
    const FVector Extent = Xform.TransformVector(*PcbSize * 0.5f).GetAbs();
    const FBox BoardBox(Center - Extent, Center + Extent);
    for (FLevelEditorViewportClient* Client : GEditor->GetLevelViewportClients())
    {
        if (!Client) { continue; }
        const FIntPoint Size = Client->Viewport ? Client->Viewport->GetSizeXY() : FIntPoint::ZeroValue;
        UE_LOG(LogTemp, Display, TEXT("mbgen viewport persp=%d size=%dx%d"), Client->IsPerspective() ? 1 : 0, Size.X, Size.Y);
        if (!Client->IsPerspective() || !Client->Viewport || Size.X < 64) { continue; }
        Client->FocusViewportOnBox(BoardBox, true);
        Client->Invalidate();
        Client->TakeHighResScreenShot();
        const FVector Where = Client->GetViewLocation();
        UE_LOG(LogTemp, Display, TEXT("mbgen camera framed %.1f %.1f %.1f"), Where.X, Where.Y, Where.Z);
    }
    GEditor->RedrawLevelEditingViewports();
#endif
}

bool AMbgenBoardActor::RunTool(const FString& Args, FString& StdOut)
{
    const FString Work = FPaths::ProjectSavedDir();
    IFileManager::Get().MakeDirectory(*Work, true);
    void* ReadPipe = nullptr;
    void* WritePipe = nullptr;
    FPlatformProcess::CreatePipe(ReadPipe, WritePipe);
    int32 Code = 1;
    const FString FullExe = FPaths::ConvertRelativePathToFull(MbgenExe);
    FProcHandle Proc = FPlatformProcess::CreateProc(*FullExe, *Args, false, true, true, nullptr, 0, *FPaths::ProjectDir(), nullptr, WritePipe);
    if (!Proc.IsValid())
    {
        FPlatformProcess::ClosePipe(ReadPipe, WritePipe);
        return false;
    }
    FPlatformProcess::WaitForProc(Proc);
    FPlatformProcess::GetProcReturnCode(Proc, &Code);
    StdOut = FPlatformProcess::ReadPipe(ReadPipe);
    FPlatformProcess::CloseProc(Proc);
    FPlatformProcess::ClosePipe(ReadPipe, WritePipe);
    return Code == 0;
}

bool AMbgenBoardActor::LiveRoutingOn() const
{
    const UMbgenSettings* Settings = GetDefault<UMbgenSettings>();
    return Settings && Settings->LiveRouting && bDllOk;
}

bool AMbgenBoardActor::WriteUtf8(const FString& Path, const FString& Text)
{
    return FFileHelper::SaveStringToFile(Text, *Path, FFileHelper::EEncodingOptions::ForceUTF8WithoutBOM);
}

void AMbgenBoardActor::CloseCore()
{
    if (bDllOk && CoreSession && FnClose)
    {
        using CloseFn = void(*)(mb_session*);
        ((CloseFn)FnClose)((mb_session*)CoreSession);
    }
    CoreSession = nullptr;
    FMbgenNav::Unbind();
    if (DllHandle)
    {
        FPlatformProcess::FreeDllHandle(DllHandle);
        DllHandle = nullptr;
    }
    bDllOk = false;
}

void AMbgenBoardActor::EnsureCore()
{
    if (bDllTried)
    {
        return;
    }
    bDllTried = true;
    const UMbgenSettings* Settings = GetDefault<UMbgenSettings>();
    FString DebugRoot = FPaths::ConvertRelativePathToFull(FPaths::ProjectDir() / TEXT("../../target/debug/"));
    FString ReleaseRoot = FPaths::ConvertRelativePathToFull(FPaths::ProjectDir() / TEXT("../../target/release/"));
    FString PackRoot = FPaths::ConvertRelativePathToFull(FPaths::ProjectDir() / TEXT("Binaries/Win64/"));
    FPaths::NormalizeDirectoryName(DebugRoot);
    FPaths::NormalizeDirectoryName(ReleaseRoot);
    FPaths::NormalizeDirectoryName(PackRoot);
    TArray<FString> Candidates;
    if (Settings && !Settings->DllPath.IsEmpty() && !Settings->DllPath.Contains(TEXT("..")))
    {
        Candidates.Add(Settings->DllPath);
    }
    Candidates.Add(DebugRoot / TEXT("mbcore_c.dll"));
    Candidates.Add(ReleaseRoot / TEXT("mbcore_c.dll"));
    Candidates.Add(PackRoot / TEXT("mbcore_c.dll"));
    auto Under = [](FString Path, FString Dir) -> bool
    {
        FPaths::NormalizeFilename(Path);
        FPaths::NormalizeDirectoryName(Dir);
        Path.ReplaceInline(TEXT("\\"), TEXT("/"));
        Dir.ReplaceInline(TEXT("\\"), TEXT("/"));
        return Path.Equals(Dir, ESearchCase::IgnoreCase)
            || Path.StartsWith(Dir + TEXT("/"), ESearchCase::IgnoreCase);
    };
    auto Allowed = [&](const FString& Full) -> bool
    {
        return Under(Full, DebugRoot) || Under(Full, ReleaseRoot) || Under(Full, PackRoot);
    };
    FString Chosen;
    for (const FString& Cand : Candidates)
    {
        FString Full = FPaths::ConvertRelativePathToFull(Cand);
        FPaths::CollapseRelativeDirectories(Full);
        FPaths::NormalizeFilename(Full);
        if (Full.Contains(TEXT(".."))) { continue; }
        if (FPaths::FileExists(Full) && Allowed(Full))
        {
            Chosen = Full;
            break;
        }
    }
    auto LogDll = [this, Settings](const TCHAR* Kind)
    {
        UE_LOG(LogTemp, Display, TEXT("mbgen dll=%s"), Kind);
        UE_LOG(LogTemp, Display, TEXT("mbgen live routing=%s hz=%d"),
            LiveRoutingOn() ? TEXT("on") : TEXT("off"),
            Settings ? Settings->LiveRouteHz : 10);
    };
    if (Chosen.IsEmpty())
    {
        LogDll(TEXT("exe-fallback"));
        return;
    }
    DllHandle = FPlatformProcess::GetDllHandle(*Chosen);
    if (!DllHandle)
    {
        UE_LOG(LogTemp, Warning, TEXT("mbgen dll=exe-fallback load failed %s"), *Chosen);
        LogDll(TEXT("exe-fallback"));
        return;
    }
    FnOpen = FPlatformProcess::GetDllExport(DllHandle, TEXT("mb_session_open"));
    FnClose = FPlatformProcess::GetDllExport(DllHandle, TEXT("mb_session_close"));
    FnApply = FPlatformProcess::GetDllExport(DllHandle, TEXT("mb_apply"));
    FnRoute = FPlatformProcess::GetDllExport(DllHandle, TEXT("mb_route"));
    FnScene = FPlatformProcess::GetDllExport(DllHandle, TEXT("mb_scene"));
    FnAnchors = FPlatformProcess::GetDllExport(DllHandle, TEXT("mb_anchors"));
    FnLibrary = FPlatformProcess::GetDllExport(DllHandle, TEXT("mb_library_json"));
    FnFree = FPlatformProcess::GetDllExport(DllHandle, TEXT("mb_string_free"));
    if (!FnOpen || !FnClose || !FnApply || !FnRoute || !FnScene || !FnFree)
    {
        UE_LOG(LogTemp, Warning, TEXT("mbgen dll=exe-fallback missing export"));
        FPlatformProcess::FreeDllHandle(DllHandle);
        DllHandle = nullptr;
        LogDll(TEXT("exe-fallback"));
        return;
    }
    bDllOk = true;
    FMbgenNav::BindFromDll(DllHandle);
    LogDll(TEXT("mbcore_c"));
}

bool AMbgenBoardActor::ApplyViaDll(const FString& GestureJson, bool& bApplied, FString& Reason)
{
    using OpenFn = mb_session*(*)(const char*);
    using ApplyFn = char*(*)(mb_session*, const char*);
    using FreeFn = void(*)(char*);
    if (!bDllOk || !FnApply || !FnFree)
    {
        return false;
    }
    if (!CoreSession)
    {
        FString DesignText;
        if (!FFileHelper::LoadFileToString(DesignText, *DesignFile))
        {
            return false;
        }
        const FTCHARToUTF8 DesignUtf8(*DesignText);
        CoreSession = ((OpenFn)FnOpen)(DesignUtf8.Get());
        if (!CoreSession)
        {
            UE_LOG(LogTemp, Warning, TEXT("mbgen session open failed"));
            return false;
        }
    }
    const FTCHARToUTF8 GestureUtf8(*GestureJson);
    char* Raw = ((ApplyFn)FnApply)((mb_session*)CoreSession, GestureUtf8.Get());
    if (!Raw)
    {
        return false;
    }
    const FString Result = UTF8_TO_TCHAR(Raw);
    ((FreeFn)FnFree)(Raw);
    TSharedPtr<FJsonObject> Obj;
    TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(Result);
    if (!FJsonSerializer::Deserialize(Reader, Obj) || !Obj)
    {
        return false;
    }
    if (Obj->HasField(TEXT("error")))
    {
        Obj->TryGetStringField(TEXT("error"), Reason);
        bApplied = false;
        return true;
    }
    Obj->TryGetBoolField(TEXT("applied"), bApplied);
    if (!bApplied)
    {
        Obj->TryGetStringField(TEXT("reason"), Reason);
        return true;
    }
    const TSharedPtr<FJsonObject> Next = Obj->GetObjectField(TEXT("design"));
    FString Encoded;
    TSharedRef<TJsonWriter<>> Writer = TJsonWriterFactory<>::Create(&Encoded);
    FJsonSerializer::Serialize(Next.ToSharedRef(), Writer);
    WriteUtf8(DesignFile, Encoded);
    using SceneFn = char*(*)(mb_session*);
    if (FnScene)
    {
        char* SceneRaw = ((SceneFn)FnScene)((mb_session*)CoreSession);
        if (SceneRaw)
        {
            WriteUtf8(SceneFile, UTF8_TO_TCHAR(SceneRaw));
            ((FreeFn)FnFree)(SceneRaw);
        }
    }
    return true;
}

void AMbgenBoardActor::RememberScenePoses()
{
    BodyCentersCm.Reset();
    BodySizesCm.Reset();
    BodyRoles.Reset();
    FString Text;
    if (!FFileHelper::LoadFileToString(Text, *SceneFile))
    {
        return;
    }
    TSharedPtr<FJsonValue> Root;
    TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(Text);
    if (!FJsonSerializer::Deserialize(Reader, Root) || !Root.IsValid() || Root->Type != EJson::Array)
    {
        return;
    }
    const float ToCm = 0.0001f;
    for (const TSharedPtr<FJsonValue>& Item : Root->AsArray())
    {
        const TSharedPtr<FJsonObject> Obj = Item->AsObject();
        if (!Obj) { continue; }
        const FString Id = Obj->GetStringField(TEXT("id"));
        BodyCentersCm.Add(Id, FVector(Obj->GetNumberField(TEXT("x_um")) * ToCm, Obj->GetNumberField(TEXT("y_um")) * ToCm, Obj->GetNumberField(TEXT("z_um")) * ToCm));
        BodySizesCm.Add(Id, FVector(Obj->GetNumberField(TEXT("sx_um")) * ToCm, Obj->GetNumberField(TEXT("sy_um")) * ToCm, Obj->GetNumberField(TEXT("sz_um")) * ToCm));
        BodyRoles.Add(Id, Obj->GetStringField(TEXT("role")));
    }
}

bool AMbgenBoardActor::ApplySceneIncremental()
{
    TMap<FString, FVector> OldCenters = BodyCentersCm;
    TMap<FString, FVector> OldSizes = BodySizesCm;
    RememberScenePoses();
    bool bMovedOther = false;
    for (const TPair<FString, FVector>& Pair : BodyCentersCm)
    {
        const FVector* OldC = OldCenters.Find(Pair.Key);
        const FVector* OldS = OldSizes.Find(Pair.Key);
        const FVector* NewS = BodySizesCm.Find(Pair.Key);
        if (!OldC || !OldS || !NewS)
        {
            return false;
        }
        if (!OldS->Equals(*NewS, 0.0001f))
        {
            return false;
        }
        const FVector Delta = Pair.Value - *OldC;
        if (Delta.IsNearlyZero(0.00005f))
        {
            continue;
        }
        if (Pair.Key != SelectedId)
        {
            bMovedOther = true;
            UE_LOG(LogTemp, Display, TEXT("mbgen reflow %s"), *Pair.Key);
            if (const FString* MovedRole = BodyRoles.Find(Pair.Key); MovedRole && *MovedRole == TEXT("hdmi"))
            {
                UE_LOG(LogTemp, Display, TEXT("mbgen usb0 Place does not leave hdmi0 stale"));
            }
        }
        for (UProceduralMeshComponent* Section : Sections)
        {
            if (!Section || Section->ComponentTags.Num() == 0) { continue; }
            if (Section->ComponentTags[0].ToString() != Pair.Key) { continue; }
            if (Section->GetAttachParent() != RootComponent) { continue; }
            Section->AddRelativeLocation(Delta);
        }
        TArray<UActorComponent*> Labels;
        GetComponents(UTextRenderComponent::StaticClass(), Labels);
        for (UActorComponent* Comp : Labels)
        {
            USceneComponent* SceneComp = Cast<USceneComponent>(Comp);
            if (!SceneComp || SceneComp->ComponentTags.Num() == 0) { continue; }
            if (SceneComp->ComponentTags[0].ToString() != Pair.Key) { continue; }
            SceneComp->AddRelativeLocation(Delta);
        }
        for (UProceduralMeshComponent* Mark : AnchorMarks)
        {
            if (!Mark || Mark->ComponentTags.Num() == 0) { continue; }
            if (Mark->ComponentTags[0].ToString() != Pair.Key) { continue; }
            Mark->AddRelativeLocation(Delta);
        }
    }
    return true;
}

void AMbgenBoardActor::PaintPathStrips(const TSharedPtr<FJsonValue>& Paths)
{
    for (UProceduralMeshComponent* Strip : PathStrips)
    {
        if (Strip) { Strip->DestroyComponent(); }
    }
    PathStrips.Reset();
    if (!Paths.IsValid() || Paths->Type != EJson::Array)
    {
        return;
    }
    const float ToCm = 0.0001f;
    for (const TSharedPtr<FJsonValue>& Item : Paths->AsArray())
    {
        const TSharedPtr<FJsonObject> PathObj = Item->AsObject();
        if (!PathObj) { continue; }
        const TArray<TSharedPtr<FJsonValue>>* Hits = nullptr;
        if (!PathObj->TryGetArrayField(TEXT("hits"), Hits) || !Hits || Hits->Num() < 2)
        {
            continue;
        }
        for (int32 i = 1; i < Hits->Num(); ++i)
        {
            const TSharedPtr<FJsonObject> A = (*Hits)[i - 1]->AsObject();
            const TSharedPtr<FJsonObject> B = (*Hits)[i]->AsObject();
            if (!A || !B) { continue; }
            if (A->GetStringField(TEXT("kind")) == TEXT("Solder") || B->GetStringField(TEXT("kind")) == TEXT("Solder"))
            {
                continue;
            }
            const uint8 Layer = (uint8)A->GetIntegerField(TEXT("layer"));
            if (Layer == 1 && !bBottomView)
            {
                continue;
            }
            const FVector Pa(A->GetNumberField(TEXT("x_um")) * ToCm, A->GetNumberField(TEXT("y_um")) * ToCm, Layer == 0 ? PcbTopCm() : PcbBotCm());
            const FVector Pb(B->GetNumberField(TEXT("x_um")) * ToCm, B->GetNumberField(TEXT("y_um")) * ToCm, Layer == 0 ? PcbTopCm() : PcbBotCm());
            const FVector Mid = (Pa + Pb) * 0.5f;
            const float Len = FVector::Dist(Pa, Pb);
            if (Len < 0.001f) { continue; }
            UProceduralMeshComponent* Strip = NewObject<UProceduralMeshComponent>(this);
            Strip->SetCanEverAffectNavigation(false);
            Strip->SetupAttachment(RootComponent);
            Strip->SetCollisionEnabled(ECollisionEnabled::NoCollision);
            const FVector H(Len * 0.5f, 0.02f, 0.01f);
            TArray<FVector> V;
            TArray<int32> Idx;
            TArray<FVector> N;
            TArray<FVector2D> UV;
            TArray<FLinearColor> C;
            TArray<FProcMeshTangent> T;
            const FVector Dir = (Pb - Pa).GetSafeNormal();
            const FRotator Rot = Dir.Rotation();
            const FTransform Xf(Rot, Mid);
            const FVector Corners[8] = {
                Xf.TransformPosition(FVector(-H.X,-H.Y,-H.Z)), Xf.TransformPosition(FVector(H.X,-H.Y,-H.Z)),
                Xf.TransformPosition(FVector(H.X,H.Y,-H.Z)), Xf.TransformPosition(FVector(-H.X,H.Y,-H.Z)),
                Xf.TransformPosition(FVector(-H.X,-H.Y,H.Z)), Xf.TransformPosition(FVector(H.X,-H.Y,H.Z)),
                Xf.TransformPosition(FVector(H.X,H.Y,H.Z)), Xf.TransformPosition(FVector(-H.X,H.Y,H.Z))
            };
            const int32 Faces[6][4] = {{4,5,6,7},{0,3,2,1},{3,7,6,2},{0,1,5,4},{1,2,6,5},{0,4,7,3}};
            for (int32 f = 0; f < 6; ++f)
            {
                const int32 b = V.Num();
                const FVector EdgeU = Corners[Faces[f][1]] - Corners[Faces[f][0]];
                const FVector FaceN = FVector::CrossProduct(EdgeU, Corners[Faces[f][2]] - Corners[Faces[f][0]]).GetSafeNormal();
                const FProcMeshTangent FaceTan(EdgeU.GetSafeNormal(), false);
                for (int32 k = 0; k < 4; ++k) { V.Add(Corners[Faces[f][k]]); C.Add(FLinearColor(0.2f, 0.85f, 0.35f)); UV.Add(FVector2D(k==1||k==2, k>=2)); N.Add(FaceN); T.Add(FaceTan); }
                Idx.Append({b, b+1, b+2, b, b+2, b+3});
            }
            Strip->CreateMeshSection_LinearColor(0, V, Idx, N, UV, C, T, false);
            Strip->RegisterComponent();
            PathStrips.Add(Strip);
        }
    }
}

void AMbgenBoardActor::RouteAndPaint(int32 DirtyOnly)
{
    if (!LiveRoutingOn() || !FnRoute || !FnFree || !CoreSession)
    {
        return;
    }
    using RouteFn = char*(*)(mb_session*, int);
    using FreeFn = void(*)(char*);
    const double T0 = FPlatformTime::Seconds();
    char* Raw = ((RouteFn)FnRoute)((mb_session*)CoreSession, DirtyOnly);
    const double RouteMs = (FPlatformTime::Seconds() - T0) * 1000.0;
    if (!Raw)
    {
        return;
    }
    const FString Text = UTF8_TO_TCHAR(Raw);
    ((FreeFn)FnFree)(Raw);
    TSharedPtr<FJsonObject> Obj;
    TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(Text);
    if (!FJsonSerializer::Deserialize(Reader, Obj) || !Obj)
    {
        return;
    }
    const TArray<TSharedPtr<FJsonValue>>* Nets = nullptr;
    const TArray<TSharedPtr<FJsonValue>>* Paths = nullptr;
    const TArray<TSharedPtr<FJsonValue>>* Errors = nullptr;
    Obj->TryGetArrayField(TEXT("nets"), Nets);
    Obj->TryGetArrayField(TEXT("paths"), Paths);
    Obj->TryGetArrayField(TEXT("errors"), Errors);
    int32 Open = 0;
    int32 Unroutable = 0;
    if (Errors)
    {
        for (const TSharedPtr<FJsonValue>& Err : *Errors)
        {
            const TSharedPtr<FJsonObject> E = Err->AsObject();
            if (!E) { continue; }
            const FString Kind = E->GetStringField(TEXT("kind"));
            if (Kind == TEXT("OpenRequired")) { Open += 1; }
            if (Kind == TEXT("Unroutable")) { Unroutable += 1; }
        }
    }
    const double P0 = FPlatformTime::Seconds();
    TSharedPtr<FJsonValue> PathVal;
    if (Paths)
    {
        PathVal = MakeShared<FJsonValueArray>(*Paths);
        LastPaths = PathVal;
        PaintPathStrips(PathVal);
    }
    PaintNetErrorBadges(Errors);
    const double PaintMs = (FPlatformTime::Seconds() - P0) * 1000.0;
    UE_LOG(LogTemp, Display, TEXT("mbgen nets=%d open=%d unroutable=%d paths=%d um"), Nets ? Nets->Num() : 0, Open, Unroutable, Paths ? Paths->Num() : 0);
    UE_LOG(LogTemp, Display, TEXT("mbgen route dirty=%d ms=%.2f grid=250 paint_ms=%.2f"), DirtyOnly, RouteMs, PaintMs);
}

void AMbgenBoardActor::ApplyBottomFlag()
{
    const bool bBottom = bBottomToggle || bCameraBelow;
    if (bBottom == bBottomView)
    {
        return;
    }
    bBottomView = bBottom;
    UE_LOG(LogTemp, Display, TEXT("mbgen bottom=%d cam=%d toggle=%d"), bBottomView ? 1 : 0, bCameraBelow ? 1 : 0, bBottomToggle ? 1 : 0);
    if (LastPaths.IsValid())
    {
        PaintPathStrips(LastPaths);
    }
}

void AMbgenBoardActor::UpdateBottomView(const FVector& CameraWorld)
{
    const FVector Mid = GetActorTransform().TransformPosition(FVector(0.f, 0.f, PcbMidCm()));
    bCameraBelow = CameraWorld.Z < Mid.Z;
    ApplyBottomFlag();
}

void AMbgenBoardActor::ToggleBottomView()
{
    bBottomToggle = !bBottomToggle;
    ApplyBottomFlag();
}

void AMbgenBoardActor::ApplyGestureJson(const FString& GestureJson, bool bIncremental)
{
    {
        const FTCHARToUTF8 Utf8(*GestureJson);
        if (Utf8.Length() > 256 * 1024)
        {
            UE_LOG(LogTemp, Warning, TEXT("mbgen kept the previous design: gesture too large"));
            return;
        }
    }
    EnsureCore();
    const double T0 = FPlatformTime::Seconds();
    bool bApplied = false;
    FString Reason;
    bool bUsedDll = false;
    if (bDllOk)
    {
        bUsedDll = ApplyViaDll(GestureJson, bApplied, Reason);
    }
    if (!bUsedDll)
    {
        const FString GesturePath = FPaths::ProjectSavedDir() / TEXT("gesture.json");
        const FString ResultPath = FPaths::ProjectSavedDir() / TEXT("preview.json");
        FFileHelper::SaveStringToFile(GestureJson, *GesturePath);
        FString Out;
        const FString Args = FString::Printf(TEXT("preview --design \"%s\" --gesture \"%s\" --out \"%s\""), *DesignFile, *GesturePath, *ResultPath);
        if (!RunTool(Args, Out))
        {
            UE_LOG(LogTemp, Warning, TEXT("mbgen preview failed"));
            return;
        }
        FString Result;
        if (!FFileHelper::LoadFileToString(Result, *ResultPath)) { return; }
        TSharedPtr<FJsonObject> Obj;
        TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(Result);
        if (!FJsonSerializer::Deserialize(Reader, Obj) || !Obj) { return; }
        Obj->TryGetBoolField(TEXT("applied"), bApplied);
        if (!bApplied)
        {
            Obj->TryGetStringField(TEXT("reason"), Reason);
        }
        else
        {
            const TSharedPtr<FJsonObject> Next = Obj->GetObjectField(TEXT("design"));
            FString Encoded;
            TSharedRef<TJsonWriter<>> Writer = TJsonWriterFactory<>::Create(&Encoded);
            FJsonSerializer::Serialize(Next.ToSharedRef(), Writer);
            FFileHelper::SaveStringToFile(Encoded, *DesignFile);
            const FString SceneArgs = FString::Printf(TEXT("scene --design \"%s\" --out \"%s\""), *DesignFile, *SceneFile);
            RunTool(SceneArgs, Out);
            if (CoreSession && FnClose)
            {
                using CloseFn = void(*)(mb_session*);
                ((CloseFn)FnClose)((mb_session*)CoreSession);
                CoreSession = nullptr;
            }
        }
    }
    if (!bApplied)
    {
        UE_LOG(LogTemp, Warning, TEXT("mbgen kept the previous design: %s"), *Reason);
        return;
    }
    if (!bIncremental)
    {
        FString Json;
        if (FFileHelper::LoadFileToString(Json, *DesignFile))
        {
            FString Op = TEXT("gesture");
            if (GestureJson.Contains(TEXT("\"op\":\"")))
            {
                const int32 A = GestureJson.Find(TEXT("\"op\":\""));
                Op = GestureJson.Mid(A + 6, 16);
                Op.Split(TEXT("\""), &Op, nullptr);
            }
            FMbgenStore::PushUndo(Json, Op);
        }
    }
    const bool bOutline = GestureJson.Contains(TEXT("\"op\":\"set_outline\""));
    if (bOutline)
    {
        RefreshSolderTextures();
    }
    if (bIncremental && ApplySceneIncremental())
    {
        bPlaceDirty = true;
    }
    else
    {
        bPlaceDirty = false;
        RebuildFromDesign();
        if (bOutline && !SelectedId.IsEmpty() && !ReadPortIds(DesignFile).Contains(SelectedId))
        {
            SelectedId.Empty();
            PaintAnchors();
            UE_LOG(LogTemp, Display, TEXT("mbgen selected"));
        }
        RefreshOpenSheets();
        if (bOutline)
        {
            UMbgenLibraryWidget::InvalidateThumbs();
            UMbgenOutlineWidget::RefreshAll();
            UMbgenPackageWidget::RefreshAll();
            RefreshLabels();
            FrameOrbit();
        }
    }
    if (LiveRoutingOn())
    {
        RouteAndPaint(bIncremental ? 1 : 0);
    }
    const double Ms = (FPlatformTime::Seconds() - T0) * 1000.0;
    if (bIncremental)
    {
        if (Ms > 8.0)
        {
            UE_LOG(LogTemp, Warning, TEXT("mbgen paint_ms=%.2f over 8 ms budget"), Ms);
        }
        else
        {
            UE_LOG(LogTemp, Display, TEXT("mbgen paint_ms=%.2f"), Ms);
        }
    }
}

void AMbgenBoardActor::CompileBoard()
{
    const FString OutDir = FPaths::ProjectContentDir() / TEXT("Boards/product");
    IFileManager::Get().MakeDirectory(*OutDir, true);
    FString Log;
    const FString Args = FString::Printf(TEXT("compile --design \"%s\" --out \"%s\""), *DesignFile, *OutDir);
    if (!RunTool(Args, Log))
    {
        UE_LOG(LogTemp, Warning, TEXT("mbgen compile failed"));
        return;
    }
    FString ErrText;
    const FString ErrPath = OutDir / TEXT("errors.json");
    if (FFileHelper::LoadFileToString(ErrText, *ErrPath))
    {
        TSharedPtr<FJsonValue> ErrRoot;
        TSharedRef<TJsonReader<>> ErrReader = TJsonReaderFactory<>::Create(ErrText);
        if (FJsonSerializer::Deserialize(ErrReader, ErrRoot) && ErrRoot.IsValid() && ErrRoot->Type == EJson::Array)
        {
            const TArray<TSharedPtr<FJsonValue>>& ErrArr = ErrRoot->AsArray();
            PaintNetErrorBadges(&ErrArr);
        }
    }
    const FString Boards = FPaths::ProjectContentDir() / TEXT("Boards");
    const TCHAR* Witness[] = { TEXT("firmware.json"), TEXT("platform.json"), TEXT("board.net"), TEXT("design_skidl.py") };
    for (const TCHAR* Name : Witness)
    {
        IFileManager::Get().Copy(*(Boards / Name), *(OutDir / Name), true);
    }
    auto ArrayCount = [](const FString& Path) -> int32
    {
        FString Text;
        if (!FFileHelper::LoadFileToString(Text, *Path)) { return 0; }
        TSharedPtr<FJsonValue> Root;
        TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(Text);
        if (!FJsonSerializer::Deserialize(Reader, Root) || !Root.IsValid() || Root->Type != EJson::Array) { return 0; }
        return Root->AsArray().Num();
    };
    auto KindCount = [](const FString& Path, const TCHAR* Kind) -> int32
    {
        FString Text;
        if (!FFileHelper::LoadFileToString(Text, *Path)) { return 0; }
        TSharedPtr<FJsonValue> Root;
        TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(Text);
        if (!FJsonSerializer::Deserialize(Reader, Root) || !Root.IsValid() || Root->Type != EJson::Array) { return 0; }
        int32 N = 0;
        for (const TSharedPtr<FJsonValue>& Item : Root->AsArray())
        {
            const TSharedPtr<FJsonObject> Obj = Item->AsObject();
            if (Obj && Obj->GetStringField(TEXT("kind")) == Kind) { N += 1; }
        }
        return N;
    };
    const FString ErrPathForLog = OutDir / TEXT("errors.json");
    UE_LOG(LogTemp, Display, TEXT("mbgen nets=%d open=%d unroutable=%d paths=%d um"),
        ArrayCount(OutDir / TEXT("nets.json")),
        KindCount(ErrPathForLog, TEXT("OpenRequired")),
        KindCount(ErrPathForLog, TEXT("Unroutable")),
        ArrayCount(OutDir / TEXT("paths.json")));
    RefreshOpenSheets();
    UE_LOG(LogTemp, Display, TEXT("mbgen compile wrote %s"), *OutDir);
}
