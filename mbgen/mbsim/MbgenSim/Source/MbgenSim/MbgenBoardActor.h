#pragma once
#include "CoreMinimal.h"
#include "Dom/JsonValue.h"
#include "GameFramework/Actor.h"
#include "MbgenNav.h"
#include "MbgenBoardActor.generated.h"

class UProceduralMeshComponent;

UCLASS()
class MBGENSIM_API AMbgenBoardActor : public AActor
{
    GENERATED_BODY()
public:
    AMbgenBoardActor();
    UFUNCTION(CallInEditor, Category = "mbgen")
    void RebuildFromDesign();
    UFUNCTION(CallInEditor, Category = "mbgen")
    void CompileBoard();
    UFUNCTION(CallInEditor, Category = "mbgen")
    void ProbeVisibility();
    UFUNCTION(CallInEditor, Category = "mbgen")
    void FrameViewport();
    UPROPERTY(EditAnywhere, Category = "mbgen")
    FString SceneFile;
    UPROPERTY(EditAnywhere, Category = "mbgen")
    FString DesignFile;
    UPROPERTY(EditAnywhere, Category = "mbgen")
    FString MbgenExe;
    UPROPERTY(VisibleAnywhere, Category = "mbgen")
    FString SelectedId;
    void ApplyGestureJson(const FString& GestureJson, bool bIncremental = false);
    /* Snapshot the design at mouse-down so Escape can restore it exactly. */
    void BeginPlaceDrag();
    void FinishPlaceDrag();
    /* Escape during a drag: restore the mouse-down design, no undo entry. Returns true if a drag was cancelled. */
    bool CancelPlaceDrag();
    bool IsPlaceDragActive() const { return bPlaceDragActive; }
    void UpdateBottomView(const FVector& CameraWorld);
    void ToggleBottomView();
    bool RunTool(const FString& Args, FString& StdOut);
    bool BoardPlaneUm(const FVector& WorldOrigin, const FVector& WorldDir, int64& OutXUm, int64& OutYUm) const;
    /* bFinal: the mouse-up sample; bypasses the 10 Hz gate so a drag ends under the cursor. */
    void PlaceSelectedAtRay(const FVector& WorldOrigin, const FVector& WorldDir, bool bFinal = false);
    void NudgeSelectedOnPlane(int32 AlongX, int32 AlongY, bool bFine);
    void TurnSelected();
    bool HitWorldOnBoard(const FVector& WorldOrigin, const FVector& WorldDir, FVector& OutWorld) const;
    bool HitDeskWorld(const FVector& WorldOrigin, const FVector& WorldDir, FVector& OutWorld) const;
    /* Finite rest plane in world units for the shared nav law (FMbgenNav). */
    bool NavDeskWorld(FMbgenNavDesk& OutDesk) const;
    /* Empty-click nav pivot: desk hit inside the pad, else on-ray at the last focus depth. */
    FVector NavPickPivotWorld(const FVector& WorldOrigin, const FVector& WorldDir, const FVector& LastPivot) const;
    void DropRoleAtRay(const FString& RoleId, const FVector& WorldOrigin, const FVector& WorldDir);
    void DeleteSelected();
    void PaintAnchors();
    void RefreshLibraryFile();
    void RefreshLabels();
    void RecaptureThumb(const FString& RoleId);
    void RefreshSolderTextures();
    static bool IsEditablePart(const FString& Id);
    static AMbgenBoardActor* FindLive(UWorld* Hint = nullptr);
    FString PortRole(const FString& Id) const;
    FString PropertyHostId() const;
    void CopySelected();
    void CopyPartToStore();
    void PastePartFromStore();
    void ReloadDesignFromDisk();
    void AddRole(const FString& RoleId);
    void SelectPart(const FString& Id);
    void RefreshOpenSheets();
    void RefreshPoseFields();
    bool PartXyUm(const FString& Id, int64& OutXUm, int64& OutYUm) const;
    UFUNCTION(CallInEditor, Category = "mbgen")
    void FrameOrbit();
    UFUNCTION(CallInEditor, Category = "mbgen")
    void DiagnoseNav();
    bool DeskCornersWorld(FVector OutCorners[4]) const;
protected:
    virtual void BeginPlay() override;
    virtual void EndPlay(const EEndPlayReason::Type EndPlayReason) override;
private:
    UPROPERTY()
    TArray<TObjectPtr<UProceduralMeshComponent>> Sections;
    UPROPERTY()
    TArray<TObjectPtr<UProceduralMeshComponent>> PathStrips;
    UPROPERTY()
    TArray<TObjectPtr<UProceduralMeshComponent>> AnchorMarks;
    TMap<FString, FVector> BodyCentersCm;
    TMap<FString, FVector> BodySizesCm;
    TMap<FString, FString> BodyRoles;
    double LastPlaceTime = 0.0;
    bool bPlaceDirty = false;
    bool bPlaceDragActive = false;
    FString DragBaseJson;
    bool bDllTried = false;
    bool bDllOk = false;
    bool bBottomView = false;
    bool bBottomToggle = false;
    bool bCameraBelow = false;
    TSharedPtr<class FJsonValue> LastPaths;
    void* DllHandle = nullptr;
    void* CoreSession = nullptr;
    void* FnOpen = nullptr;
    void* FnClose = nullptr;
    void* FnApply = nullptr;
    void* FnRoute = nullptr;
    void* FnScene = nullptr;
    void* FnAnchors = nullptr;
    void* FnLibrary = nullptr;
    void* FnFree = nullptr;
    void ApplySettingsPaths();
    bool ShouldThrottlePlace() const;
    void EnsureCore();
    void CloseCore();
    bool LiveRoutingOn() const;
    bool ApplyViaDll(const FString& GestureJson, bool& bApplied, FString& Reason);
    bool WriteUtf8(const FString& Path, const FString& Text);
    bool ApplySceneIncremental();
    void RememberScenePoses();
    float PcbTopCm() const;
    float PcbMidCm() const;
    float PcbBotCm() const;
    void PaintPathStrips(const TSharedPtr<FJsonValue>& Paths);
    void RouteAndPaint(int32 DirtyOnly);
    void ApplyBottomFlag();
    void ClearPreviewMeshes();
    void AddBox(const FVector& CenterIn, const FVector& SizeCm, const FLinearColor& Color, const FString& MaterialName, const FString& PartId, const FString& PartRole, int32 YawQ);
    void PlaceBadge(const FVector& CenterCm, const FString& Text, const FString& Tag, const FColor& Color);
    void PaintGapBadges();
    void PaintNetErrorBadges(const TArray<TSharedPtr<FJsonValue>>* Errors);
    void ClearBadgesWithTag(const FString& Tag);
};
