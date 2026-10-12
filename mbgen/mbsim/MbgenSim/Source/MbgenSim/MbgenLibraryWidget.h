#pragma once
#include "CoreMinimal.h"
#include "Blueprint/UserWidget.h"
#include "Styling/SlateBrush.h"
#include "MbgenLibraryWidget.generated.h"

struct FMbgenLibraryRow
{
    FString Id;
    FString Role;
    FString Support;
    FString Domain;
    FString Vendor;
    FString Mpn;
    FString Lcsc;
    FString Note;
    bool bHatch = false;
    TArray<FString> Labels;
    TArray<FString> Contracts;
};

UCLASS()
class MBGENSIM_API UMbgenLibraryWidget : public UUserWidget
{
    GENERATED_BODY()
public:
    virtual TSharedRef<SWidget> RebuildWidget() override;
    virtual FReply NativeOnMouseButtonDown(const FGeometry& Geo, const FPointerEvent& Event) override;
    virtual FReply NativeOnMouseMove(const FGeometry& Geo, const FPointerEvent& Event) override;
    virtual FReply NativeOnMouseButtonUp(const FGeometry& Geo, const FPointerEvent& Event) override;
    static void BeginRoleDrag(const FString& Role);
    static void NoteRoleDragMove(const FVector2D& Pos);
    static bool TakeRoleDrop(FString& OutRole);
    static void CancelRoleDrag();
    static bool RoleDragMoved();
    static bool IsRoleDrag();
    static void InvalidateThumbs();
    static void RefreshOpenLists();
private:
    bool bDragging = false;
    FVector2D DragStart = FVector2D::ZeroVector;
    TSharedPtr<SWidget> Header;
    FString Filter;
    TArray<FMbgenLibraryRow> Rows;
    TSharedPtr<class SScrollBox> List;
    UPROPERTY()
    TArray<TObjectPtr<UTexture2D>> LoadedThumbs;
    TArray<TSharedPtr<FSlateBrush>> BrushKeep;
    void LoadRows();
    void FillList();
    void ReloadThumbs();
    static void EnsureThumbs();
    void OnSearch(const FText& Text);
    void AddRole(const FString& Role);
    bool RowMatches(const FMbgenLibraryRow& Row) const;
    TSharedRef<SWidget> MakeThumb(const FMbgenLibraryRow& Row, bool& bUsedFile);
};
