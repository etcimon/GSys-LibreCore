#include "MbgenPackageWidget.h"
#include "MbgenBoardActor.h"
#include "MbgenPlayerController.h"
#include "EngineUtils.h"
#include "Widgets/SBoxPanel.h"
#include "Widgets/Input/SButton.h"
#include "Widgets/Text/STextBlock.h"
#include "Dom/JsonObject.h"
#include "Serialization/JsonSerializer.h"
#include "Misc/FileHelper.h"
#include "Misc/Paths.h"
#include "UObject/UObjectIterator.h"

TSharedRef<SWidget> UMbgenPackageWidget::RebuildWidget()
{
    Header = SNew(STextBlock).Text(FText::FromString(TEXT("Processor — drag the title. A row applies a real config package.")));
    Rows = SNew(SVerticalBox);
    FillRows();
    return SNew(SVerticalBox)
        + SVerticalBox::Slot().AutoHeight().Padding(8)
        [ Header.ToSharedRef() ]
        + SVerticalBox::Slot().FillHeight(1.f)
        [ Rows.ToSharedRef() ];
}

void UMbgenPackageWidget::FillRows()
{
    if (!Rows.IsValid()) { return; }
    Rows->ClearChildren();
    FString Current = TEXT("cv64a6_imafdc_sv39");
    AMbgenBoardActor* Board = AMbgenBoardActor::FindLive(GetWorld());
    if (Board)
    {
        FString DesignText;
        if (FFileHelper::LoadFileToString(DesignText, *Board->DesignFile))
        {
            TSharedPtr<FJsonValue> Root;
            TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(DesignText);
            if (FJsonSerializer::Deserialize(Reader, Root) && Root.IsValid() && Root->AsObject())
            {
                const TSharedPtr<FJsonObject>* Settings = nullptr;
                if (Root->AsObject()->TryGetObjectField(TEXT("settings"), Settings) && Settings)
                {
                    const FString Pid = (*Settings)->GetStringField(TEXT("package_id"));
                    if (!Pid.IsEmpty()) { Current = Pid; }
                }
            }
        }
    }
    FString Text;
    const FString Path = FPaths::ProjectContentDir() / TEXT("Boards/packages.json");
    if (!FFileHelper::LoadFileToString(Text, *Path)) { return; }
    TSharedPtr<FJsonValue> Root;
    TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(Text);
    if (!FJsonSerializer::Deserialize(Reader, Root) || !Root.IsValid() || Root->Type != EJson::Array) { return; }
    for (const TSharedPtr<FJsonValue>& Item : Root->AsArray())
    {
        const TSharedPtr<FJsonObject> Obj = Item->AsObject();
        if (!Obj) { continue; }
        const FString Id = Obj->GetStringField(TEXT("id"));
        FString Label = FString::Printf(TEXT("%s  %s  cores %d  %s"),
            *Id, *Obj->GetStringField(TEXT("isa")), (int32)Obj->GetNumberField(TEXT("cores")),
            Obj->GetBoolField(TEXT("ai")) ? TEXT("AI") : TEXT(""));
        if (Id == Current) { Label += TEXT("  current"); }
        Rows->AddSlot().AutoHeight().Padding(4, 1)
        [
            SNew(SButton)
            .OnClicked_Lambda([this, Id]() { ApplyPackage(Id); return FReply::Handled(); })
            [
                SNew(STextBlock).Text(FText::FromString(Label))
            ]
        ];
    }
}

void UMbgenPackageWidget::RefreshAll()
{
    for (TObjectIterator<UMbgenPackageWidget> It; It; ++It)
    {
        if (IsValid(*It)) { It->FillRows(); }
    }
}

FReply UMbgenPackageWidget::NativeOnMouseButtonDown(const FGeometry& Geo, const FPointerEvent& Event)
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

FReply UMbgenPackageWidget::NativeOnMouseMove(const FGeometry& Geo, const FPointerEvent& Event)
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

FReply UMbgenPackageWidget::NativeOnMouseButtonUp(const FGeometry& Geo, const FPointerEvent& Event)
{
    bDragging = false;
    return FReply::Handled().ReleaseMouseCapture();
}

void UMbgenPackageWidget::ApplyPackage(const FString& PackageId)
{
    AMbgenBoardActor* Board = AMbgenBoardActor::FindLive(GetWorld());
    if (!Board) { return; }
    const FString Id = Board->PropertyHostId();
    if (Id.IsEmpty()) { return; }
    Board->ApplyGestureJson(FString::Printf(
        TEXT("{\"op\":\"set_property\",\"id\":\"%s\",\"key\":\"package_id\",\"value\":\"%s\"}"),
        *Id, *PackageId));
    RefreshAll();
}
