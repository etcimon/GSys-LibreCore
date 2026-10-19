#pragma once
#include "CoreMinimal.h"
#include "Blueprint/UserWidget.h"
#include "MbgenIssuesWidget.generated.h"

/* Issues — the resolved circuit's diagnostics (mb_circuit), one row per
   finding with its rule id and the part / pin / net it is about. Clicking a
   row selects the linked part on the board. Shared by the editor window
   and the standalone viewport; refreshed after every applied gesture. */
UCLASS()
class MBGENSIM_API UMbgenIssuesWidget : public UUserWidget
{
    GENERATED_BODY()
public:
    virtual TSharedRef<SWidget> RebuildWidget() override;
    virtual FReply NativeOnMouseButtonDown(const FGeometry& Geo, const FPointerEvent& Event) override;
    virtual FReply NativeOnMouseMove(const FGeometry& Geo, const FPointerEvent& Event) override;
    virtual FReply NativeOnMouseButtonUp(const FGeometry& Geo, const FPointerEvent& Event) override;
    static void RefreshAll();
private:
    bool bDragging = false;
    FVector2D DragStart = FVector2D::ZeroVector;
    TSharedPtr<class SWidget> Header;
    TSharedPtr<class STextBlock> Summary;
    TSharedPtr<class SVerticalBox> Rows;
    void FillRows();
    void SelectIssue(const FString& PartId, const FString& PinId, const FString& NetId);
};
