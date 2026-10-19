#pragma once
#include "CoreMinimal.h"
#include "Blueprint/UserWidget.h"
#include "MbgenOutlineWidget.generated.h"

UCLASS()
class MBGENSIM_API UMbgenOutlineWidget : public UUserWidget
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
    TSharedPtr<class SVerticalBox> Rows;
    TSharedPtr<class SVerticalBox> Proposal;
    void FillRows();
    /* mb_outline_proposal: kept / re-edged / dropped (with reasons) / stock added, then an Apply button. */
    void PreviewOutline(const FString& TemplateId);
    void ApplyOutline(const FString& TemplateId);
};
