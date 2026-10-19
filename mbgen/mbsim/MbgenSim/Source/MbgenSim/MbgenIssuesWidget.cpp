#include "MbgenIssuesWidget.h"
#include "MbgenBoardActor.h"
#include "Widgets/SBoxPanel.h"
#include "Widgets/Input/SButton.h"
#include "Widgets/Layout/SScrollBox.h"
#include "Widgets/Text/STextBlock.h"
#include "Dom/JsonObject.h"
#include "Serialization/JsonSerializer.h"
#include "UObject/UObjectIterator.h"

TSharedRef<SWidget> UMbgenIssuesWidget::RebuildWidget()
{
    Rows = SNew(SVerticalBox);
    Summary = SNew(STextBlock).Text(FText::FromString(TEXT("…")));
    FillRows();
    Header = SNew(STextBlock).Text(FText::FromString(TEXT("Issues — the resolved circuit's findings. A row selects its part.")));
    return SNew(SVerticalBox)
        + SVerticalBox::Slot().AutoHeight().Padding(8)
        [ Header.ToSharedRef() ]
        + SVerticalBox::Slot().AutoHeight().Padding(8, 0, 8, 6)
        [ Summary.ToSharedRef() ]
        + SVerticalBox::Slot().FillHeight(1.f)
        [
            SNew(SScrollBox)
            + SScrollBox::Slot()
            [ Rows.ToSharedRef() ]
        ];
}

static FString Field(const TSharedPtr<FJsonObject>& Obj, const TCHAR* Key)
{
    FString Out;
    if (Obj.IsValid()) { Obj->TryGetStringField(Key, Out); }
    return Out;
}

void UMbgenIssuesWidget::FillRows()
{
    if (!Rows.IsValid()) { return; }
    Rows->ClearChildren();
    AMbgenBoardActor* Board = AMbgenBoardActor::FindLive(GetWorld());
    if (!Board)
    {
        if (Summary.IsValid()) { Summary->SetText(FText::FromString(TEXT("no live board"))); }
        return;
    }
    const FString Text = Board->CircuitJson();
    TSharedPtr<FJsonObject> Circuit;
    TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(Text);
    if (Text.IsEmpty() || !FJsonSerializer::Deserialize(Reader, Circuit) || !Circuit.IsValid())
    {
        if (Summary.IsValid()) { Summary->SetText(FText::FromString(TEXT("circuit unavailable (no DLL and no mbgen exe)"))); }
        return;
    }
    const TArray<TSharedPtr<FJsonValue>>* Diags = nullptr;
    Circuit->TryGetArrayField(TEXT("diagnostics"), Diags);
    int32 Errors = 0;
    int32 Warnings = 0;
    int32 Infos = 0;
    if (Diags)
    {
        for (const TSharedPtr<FJsonValue>& V : *Diags)
        {
            const TSharedPtr<FJsonObject> D = V->AsObject();
            if (!D.IsValid()) { continue; }
            const FString Severity = Field(D, TEXT("severity"));
            if (Severity == TEXT("error")) { Errors += 1; }
            else if (Severity == TEXT("warning")) { Warnings += 1; }
            else { Infos += 1; }
            const FString Rule = Field(D, TEXT("rule"));
            const FString Message = Field(D, TEXT("message"));
            const FString Part = Field(D, TEXT("part"));
            const FString Pin = Field(D, TEXT("pin"));
            const FString Net = Field(D, TEXT("net"));
            FString Where;
            if (!Pin.IsEmpty()) { Where = Pin; }
            else if (!Part.IsEmpty()) { Where = Part; }
            if (!Net.IsEmpty()) { Where += (Where.IsEmpty() ? TEXT("") : TEXT("  ")) + FString::Printf(TEXT("net %s"), *Net); }
            const TCHAR* Tag = Severity == TEXT("error") ? TEXT("E") : (Severity == TEXT("warning") ? TEXT("W") : TEXT("i"));
            const FString Label = FString::Printf(TEXT("[%s] %s  %s\n     %s"), Tag, *Rule, *Where, *Message);
            Rows->AddSlot().AutoHeight().Padding(4, 1)
            [
                SNew(SButton)
                .OnClicked_Lambda([this, Part, Pin, Net]() { SelectIssue(Part, Pin, Net); return FReply::Handled(); })
                [
                    SNew(STextBlock).Text(FText::FromString(Label)).AutoWrapText(true)
                ]
            ];
        }
    }
    FString Soc;
    const TSharedPtr<FJsonObject>* SocObj = nullptr;
    if (Circuit->TryGetObjectField(TEXT("soc_package"), SocObj) && SocObj && SocObj->IsValid())
    {
        const bool bApproved = (*SocObj)->GetBoolField(TEXT("approved"));
        const TArray<TSharedPtr<FJsonValue>>* Unresolved = nullptr;
        (*SocObj)->TryGetArrayField(TEXT("unresolved"), Unresolved);
        Soc = bApproved
            ? TEXT("  SoC package: approved")
            : FString::Printf(TEXT("  SoC package: %s, %d unresolved"), *Field(*SocObj, TEXT("declared_status")), Unresolved ? Unresolved->Num() : 0);
    }
    const TArray<TSharedPtr<FJsonValue>>* Nets = nullptr;
    const TArray<TSharedPtr<FJsonValue>>* Comps = nullptr;
    Circuit->TryGetArrayField(TEXT("nets"), Nets);
    Circuit->TryGetArrayField(TEXT("components"), Comps);
    if (Summary.IsValid())
    {
        Summary->SetText(FText::FromString(FString::Printf(
            TEXT("%d error%s  %d warning%s  %d info  ·  %d parts  %d nets%s"),
            Errors, Errors == 1 ? TEXT("") : TEXT("s"),
            Warnings, Warnings == 1 ? TEXT("") : TEXT("s"),
            Infos, Comps ? Comps->Num() : 0, Nets ? Nets->Num() : 0, *Soc)));
    }
}

void UMbgenIssuesWidget::SelectIssue(const FString& PartId, const FString& PinId, const FString& NetId)
{
    AMbgenBoardActor* Board = AMbgenBoardActor::FindLive(GetWorld());
    if (!Board) { return; }
    FString Part = PartId;
    if (Part.IsEmpty() && !PinId.IsEmpty())
    {
        int32 Dot = INDEX_NONE;
        if (PinId.FindLastChar(TEXT('.'), Dot)) { Part = PinId.Left(Dot); }
    }
    if (!Part.IsEmpty() && AMbgenBoardActor::IsEditablePart(Part))
    {
        Board->SelectPart(Part);
    }
    UE_LOG(LogTemp, Display, TEXT("mbgen issue part=%s pin=%s net=%s"), *Part, *PinId, *NetId);
}

void UMbgenIssuesWidget::RefreshAll()
{
    for (TObjectIterator<UMbgenIssuesWidget> It; It; ++It)
    {
        if (IsValid(*It) && It->Rows.IsValid()) { It->FillRows(); }
    }
}

FReply UMbgenIssuesWidget::NativeOnMouseButtonDown(const FGeometry& Geo, const FPointerEvent& Event)
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

FReply UMbgenIssuesWidget::NativeOnMouseMove(const FGeometry& Geo, const FPointerEvent& Event)
{
    if (bDragging)
    {
        const FVector2D Now = Event.GetScreenSpacePosition();
        const FVector2D Delta = Now - DragStart;
        DragStart = Now;
        SetPositionInViewport(GetCachedGeometry().GetAbsolutePosition() + Delta, false);
        return FReply::Handled();
    }
    return Super::NativeOnMouseMove(Geo, Event);
}

FReply UMbgenIssuesWidget::NativeOnMouseButtonUp(const FGeometry& Geo, const FPointerEvent& Event)
{
    bDragging = false;
    return FReply::Handled().ReleaseMouseCapture();
}
