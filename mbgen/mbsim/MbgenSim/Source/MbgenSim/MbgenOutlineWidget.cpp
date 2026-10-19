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
    Proposal = SNew(SVerticalBox);
    FillRows();
    Header = SNew(STextBlock).Text(FText::FromString(TEXT("Board — a row previews the millimetre outline change; Apply commits it. Parts keep the same pin kernel.")));
    return SNew(SVerticalBox)
        + SVerticalBox::Slot().AutoHeight().Padding(8)
        [ Header.ToSharedRef() ]
        + SVerticalBox::Slot().AutoHeight()
        [ Rows.ToSharedRef() ]
        + SVerticalBox::Slot().FillHeight(1.f).Padding(8, 6)
        [ Proposal.ToSharedRef() ];
}

static void AddLine(const TSharedPtr<SVerticalBox>& Box, const FString& Text)
{
    Box->AddSlot().AutoHeight().Padding(0, 1)
    [
        SNew(STextBlock).Text(FText::FromString(Text)).AutoWrapText(true)
    ];
}

/* Show what set_outline would do before offering to do it: a dropped part
   is a decision the user takes, not a surprise after the click. */
void UMbgenOutlineWidget::PreviewOutline(const FString& TemplateId)
{
    if (!Proposal.IsValid()) { return; }
    Proposal->ClearChildren();
    AMbgenBoardActor* Board = AMbgenBoardActor::FindLive(GetWorld());
    if (!Board) { return; }
    const FString Text = Board->OutlineProposalJson(TemplateId);
    TSharedPtr<FJsonObject> P;
    TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(Text);
    if (Text.IsEmpty() || !FJsonSerializer::Deserialize(Reader, P) || !P.IsValid() || P->HasField(TEXT("error")))
    {
        AddLine(Proposal, FString::Printf(TEXT("%s: no proposal available"), *TemplateId));
        return;
    }
    const FString From = P->GetStringField(TEXT("from"));
    if (From == TemplateId)
    {
        AddLine(Proposal, FString::Printf(TEXT("%s is the current outline."), *TemplateId));
        return;
    }
    const TArray<TSharedPtr<FJsonValue>>* Kept = nullptr;
    const TArray<TSharedPtr<FJsonValue>>* ReEdged = nullptr;
    const TArray<TSharedPtr<FJsonValue>>* Dropped = nullptr;
    const TArray<TSharedPtr<FJsonValue>>* Added = nullptr;
    const TArray<TSharedPtr<FJsonValue>>* Blocks = nullptr;
    const TArray<TSharedPtr<FJsonValue>>* Nets = nullptr;
    P->TryGetArrayField(TEXT("kept"), Kept);
    P->TryGetArrayField(TEXT("re_edged"), ReEdged);
    P->TryGetArrayField(TEXT("dropped"), Dropped);
    P->TryGetArrayField(TEXT("added_stock"), Added);
    P->TryGetArrayField(TEXT("dropped_blocks"), Blocks);
    P->TryGetArrayField(TEXT("affected_nets"), Nets);
    AddLine(Proposal, FString::Printf(TEXT("%s → %s:  %d kept, %d re-edged, %d dropped, %d stock added"),
        *From, *TemplateId, Kept ? Kept->Num() : 0, ReEdged ? ReEdged->Num() : 0, Dropped ? Dropped->Num() : 0, Added ? Added->Num() : 0));
    if (ReEdged)
    {
        for (const TSharedPtr<FJsonValue>& V : *ReEdged)
        {
            const TSharedPtr<FJsonObject> M = V->AsObject();
            if (!M.IsValid()) { continue; }
            AddLine(Proposal, FString::Printf(TEXT("  ↷ %s: %s → %s"), *M->GetStringField(TEXT("id")), *M->GetStringField(TEXT("from_edge")), *M->GetStringField(TEXT("to_edge"))));
        }
    }
    if (Dropped)
    {
        for (const TSharedPtr<FJsonValue>& V : *Dropped)
        {
            const TSharedPtr<FJsonObject> D = V->AsObject();
            if (!D.IsValid()) { continue; }
            AddLine(Proposal, FString::Printf(TEXT("  ✕ %s — %s"), *D->GetStringField(TEXT("id")), *D->GetStringField(TEXT("reason"))));
        }
    }
    if (Blocks && Blocks->Num() > 0)
    {
        AddLine(Proposal, FString::Printf(TEXT("  circuit blocks removed: %d"), Blocks->Num()));
    }
    if (Nets && Nets->Num() > 0)
    {
        TArray<FString> Names;
        for (const TSharedPtr<FJsonValue>& V : *Nets) { Names.Add(V->AsString()); }
        AddLine(Proposal, FString::Printf(TEXT("  nets losing pins: %s"), *FString::Join(Names, TEXT(", "))));
    }
    if (Added)
    {
        for (const TSharedPtr<FJsonValue>& V : *Added)
        {
            AddLine(Proposal, FString::Printf(TEXT("  + %s (stock)"), *V->AsString()));
        }
    }
    Proposal->AddSlot().AutoHeight().Padding(0, 6)
    [
        SNew(SButton)
        .OnClicked_Lambda([this, TemplateId]() { ApplyOutline(TemplateId); return FReply::Handled(); })
        [
            SNew(STextBlock).Text(FText::FromString(FString::Printf(TEXT("Apply %s"), *TemplateId)))
        ]
    ];
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
            .OnClicked_Lambda([this, Id]() { PreviewOutline(Id); return FReply::Handled(); })
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
    if (Proposal.IsValid()) { Proposal->ClearChildren(); }
}
