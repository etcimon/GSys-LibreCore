#pragma once
#include "CoreMinimal.h"
#include "Blueprint/UserWidget.h"
#include "MbgenPropertyWidget.generated.h"

UCLASS()
class MBGENSIM_API UMbgenPropertyWidget : public UUserWidget
{
    GENERATED_BODY()
public:
    virtual TSharedRef<SWidget> RebuildWidget() override;
    virtual FReply NativeOnMouseButtonDown(const FGeometry& Geo, const FPointerEvent& Event) override;
    virtual FReply NativeOnMouseMove(const FGeometry& Geo, const FPointerEvent& Event) override;
    virtual FReply NativeOnMouseButtonUp(const FGeometry& Geo, const FPointerEvent& Event) override;
    void ShowPart(const FString& Id);
    void RefreshPose();
private:
    bool bDragging = false;
    FVector2D DragStart = FVector2D::ZeroVector;
    FString PartId;
    TSharedPtr<class SWidget> Header;
    TSharedPtr<class SVerticalBox> Body;
    TSharedPtr<class SEditableTextBox> XBox;
    TSharedPtr<class SEditableTextBox> YBox;
    TArray<TSharedPtr<FString>> InterfaceOptions;
    TArray<TSharedPtr<FString>> PackageOptions;
    TSharedPtr<class SVerticalBox> RecipeBox;
    void FillSheet();
    void FillBoardSettings(class AMbgenBoardActor* Board);
    /* Circuit recipes on this part: existing blocks (remove) and a preview of
       decap_per_rail (what it adds / connects) with an Apply that is one gesture. */
    void FillRecipes(class AMbgenBoardActor* Board, const FString& Contracts);
    void PreviewRecipe(const FString& Recipe, int32 PerRail);
    void AutoConnect();
    void SetKey(const FString& Key, const FString& Value);
};
