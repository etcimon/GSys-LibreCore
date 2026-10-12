#pragma once
#include "CoreMinimal.h"
#include "GameFramework/PlayerController.h"
#include "MbgenPlayerController.generated.h"

class AMbgenBoardActor;
class UMbgenPackageWidget;
class UMbgenLibraryWidget;
class UMbgenOutlineWidget;
class UMbgenPropertyWidget;
class UMbgenChromeWidget;

UCLASS()
class MBGENSIM_API AMbgenPlayerController : public APlayerController
{
    GENERATED_BODY()
public:
    virtual void BeginPlay() override;
    virtual void SetupInputComponent() override;
    virtual void Tick(float DeltaSeconds) override;
private:
    bool bOrbit = false;
    bool bPan = false;
    bool bOrbitMoved = false;
    bool bLookDrag = false;
    bool bPlaceDrag = false;
    FVector2D OrbitDownPos = FVector2D::ZeroVector;
    TObjectPtr<UMbgenPackageWidget> PackageWindow;
    TObjectPtr<UMbgenLibraryWidget> LibraryWindow;
    TObjectPtr<UMbgenOutlineWidget> OutlineWindow;
    TObjectPtr<UMbgenPropertyWidget> PropertyWindow;
    TObjectPtr<UMbgenChromeWidget> ChromeBar;
    void ChordUndo();
    void ChordRedo();
    void ChordSave();
    void ChordOpen();
    void ChordCopy();
    void ChordPaste();
    AMbgenBoardActor* Board() const;
    void SelectUnderCursor();
    void Nudge(float AlongX, float AlongY, bool Fine);
    void TogglePackages();
    void ToggleLibrary();
    void ToggleOutline();
    void ToggleProperties();
    void ShowProperties(const FString& Id);
    void ShowPackages();
    void ToggleBottom();
    void OrbitPressed();
    void OrbitReleased();
    void PanPressed();
    void PanReleased();
    void ZoomToward(float Notches);
    void ZoomIn();
    void ZoomOut();
    void CompilePressed();
    void FramePressed();
    void PlaceReleased();
    void DeletePressed();
    void NudgeLeft();
    void NudgeRight();
    void NudgeUp();
    void NudgeDown();
};
