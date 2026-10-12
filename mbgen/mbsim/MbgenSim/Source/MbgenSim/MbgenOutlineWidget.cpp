#include "MbgenOutlineWidget.h"
#include "MbgenBoardActor.h"
#include "EngineUtils.h"
#include "Widgets/SBoxPanel.h"
#include "Widgets/Input/SButton.h"
#include "Widgets/Text/STextBlock.h"
#include "Dom/JsonObject.h"
#include "Serialization/JsonSerializer.h"
#include "Misc/FileHelper.h"
#include "Misc/Paths.h"
#include "UObject/UObjectIterator.h"

TSharedRef<SWidget> UMbgenOutlineWidget::RebuildWidget()
{
    Rows = SNew(SVerticalBox);
    FillRows();
    Header = SNew(STextBlock).Text(FText::FromString(TEXT("Board — a row swaps the millimetre outline. Parts keep the same pin kernel.")));
    return SNew(SVerticalBox)
        + SVerticalBox::Slot().AutoHeight().Padding(8)
        [ Header.ToSharedRef() ]
        + SVerticalBox::Slot().FillHeight(1.f)
        [ Rows.ToSharedRef() ];
}

void UMbgenOutlineWidget::FillRows()
{
    if (!Rows.IsValid()) { return; }
    Rows->ClearChildren();
    FString Current = TEXT("mini-itx");
    AMbgenBoardActor* Board = AMbgenBoardActor::FindLive(GetWorld());
    if (Board)
    {
        FString DesignText;
        if (FFileHelper::LoadFileToString(DesignText, *Board->DesignFile))
        {
            TSharedPtr<FJsonValue> Root;
            TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(DesignText);
            TSharedPtr<FJsonObject> Design;
            if (FJsonSerializer::Deserialize(Reader, Root) && Root.IsValid() && Root->AsObject())
            {
                Current = Root->AsObject()->GetStringField(TEXT("template_id"));
            }
        }
    }
    FString Text;
    const FString Path = FPaths::ProjectContentDir() / TEXT("Boards/outlines.json");
    if (!FFileHelper::LoadFileToString(Text, *Path)) { return; }
    TSharedPtr<FJsonValue> Root;
    TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(Text);
    if (!FJsonSerializer::Deserialize(Reader, Root) || !Root.IsValid() || Root->Type != EJson::Array) { return; }
    for (const TSharedPtr<FJsonValue>& Item : Root->AsArray())
    {
        const TSharedPtr<FJsonObject> Obj = Item->AsObject();
        if (!Obj) { continue; }
        const FString Id = Obj->GetStringField(TEXT("id"));
        const int32 W = (int32)(Obj->GetNumberField(TEXT("w_um")) / 1000.0);
        const int32 D = (int32)(Obj->GetNumberField(TEXT("d_um")) / 1000.0);
        FString Label = FString::Printf(TEXT("%s  %d × %d mm"), *Id, W, D);
        if (Id == Current) { Label += TEXT("  current"); }
        Rows->AddSlot().AutoHeight().Padding(4, 1)
        [
            SNew(SButton)
            .OnClicked_Lambda([this, Id]() { ApplyOutline(Id); return FReply::Handled(); })
            [
                SNew(STextBlock).Text(FText::FromString(Label))
            ]
        ];
    }
}

void UMbgenOutlineWidget::RefreshAll()
{
    for (TObjectIterator<UMbgenOutlineWidget> It; It; ++It)
    {
        if (IsValid(*It)) { It->FillRows(); }
    }
}

FReply UMbgenOutlineWidget::NativeOnMouseButtonDown(const FGeometry& Geo, const FPointerEvent& Event)
{
    if (Event.GetEffectingButton() == EKeys::LeftMouseButton
        && Header.IsValid()
        && Header->GetCachedGeometry().IsUnderLocation(Event.GetScreenSpacePosition()))
    {
        bDragging = true;
        DragStart = Event.GetScreenSpacePosition();
        return FReply::Handled().CaptureMouse(TakeWidget());
    }
    return Super::NativeOnMouseButtonDown(Geo, Event);
}

FReply UMbgenOutlineWidget::NativeOnMouseMove(const FGeometry& Geo, const FPointerEvent& Event)
{
    if (bDragging)
    {
        const FVector2D Now = Event.GetScreenSpacePosition();
        const FVector2D Delta = Now - DragStart;
        DragStart = Now;
        FVector2D Pos = GetCachedGeometry().GetAbsolutePosition() + Delta;
        SetPositionInViewport(Pos, false);
        return FReply::Handled();
    }
    return Super::NativeOnMouseMove(Geo, Event);
}

FReply UMbgenOutlineWidget::NativeOnMouseButtonUp(const FGeometry& Geo, const FPointerEvent& Event)
{
    bDragging = false;
    return FReply::Handled().ReleaseMouseCapture();
}

void UMbgenOutlineWidget::ApplyOutline(const FString& TemplateId)
{
    AMbgenBoardActor* Board = AMbgenBoardActor::FindLive(GetWorld());
    if (!Board) { return; }
    Board->ApplyGestureJson(FString::Printf(
        TEXT("{\"op\":\"set_outline\",\"template_id\":\"%s\"}"), *TemplateId));
}
