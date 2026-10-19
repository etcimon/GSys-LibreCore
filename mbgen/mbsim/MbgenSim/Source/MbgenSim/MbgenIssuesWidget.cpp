#include "MbgenIssuesWidget.h"
#include "MbgenBoardActor.h"
#include "Widgets/SBoxPanel.h"
#include "Widgets/Input/SButton.h"
#include "Widgets/Layout/SScrollBox.h"
#include "Widgets/Text/STextBlock.h"
#include "Dom/JsonObject.h"
#include "Serialization/JsonSerializer.h"
#include "HAL/FileManager.h"
#include "Misc/FileHelper.h"
#include "Misc/Paths.h"
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
            AddRow(FString::Printf(TEXT("[%s] %s  %s\n     %s"), Tag, *Rule, *Where, *Message), Part, Pin, Net);
        }
    }
    // Results produced from an ingested bundle of this exact circuit.
    ReadBackOutputs(Field(Circuit, TEXT("circuit_sha256")), Errors, Warnings);
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

void UMbgenIssuesWidget::AddRow(const FString& Label, const FString& PartId, const FString& PinId, const FString& NetId)
{
    Rows->AddSlot().AutoHeight().Padding(4, 1)
    [
        SNew(SButton)
        .OnClicked_Lambda([this, PartId, PinId, NetId]() { SelectIssue(PartId, PinId, NetId); return FReply::Handled(); })
        [
            SNew(STextBlock).Text(FText::FromString(Label)).AutoWrapText(true)
        ]
    ];
}

static TSharedPtr<FJsonObject> LoadJsonObject(const FString& Path)
{
    FString Text;
    if (!FFileHelper::LoadFileToString(Text, *Path)) { return nullptr; }
    TSharedPtr<FJsonObject> Obj;
    TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(Text);
    if (!FJsonSerializer::Deserialize(Reader, Obj)) { return nullptr; }
    return Obj;
}

void UMbgenIssuesWidget::ReadBackOutputs(const FString& CircuitSha, int32& OutErrors, int32& OutWarnings)
{
    if (CircuitSha.IsEmpty()) { return; }
    // mbsim/MbgenSim -> mbgen -> repo root.
    const FString BoardsRoot = FPaths::ConvertRelativePathToFull(FPaths::ProjectDir() / TEXT("../../../corev-mb/boards"));
    TArray<FString> Dirs;
    IFileManager::Get().FindFiles(Dirs, *(BoardsRoot / TEXT("*")), false, true);
    Dirs.Sort();
    for (const FString& BoardId : Dirs)
    {
        const FString BoardDir = BoardsRoot / BoardId;
        const TSharedPtr<FJsonObject> Manifest = LoadJsonObject(BoardDir / TEXT("manifest.json"));
        if (!Manifest.IsValid()) { continue; }
        const FString Source = Field(Manifest, TEXT("source_circuit_sha256"));
        if (Source != CircuitSha)
        {
            AddRow(FString::Printf(TEXT("[i] stale  boards/%s\n     ingested from a previous circuit revision; re-run mbgen compile + mb ingest"), *BoardId), FString(), FString(), FString());
            continue;
        }
        const FString Outputs = BoardDir / TEXT("outputs");
        // SKiDL / ERC findings (counted in the Python compiler; only non-mbgen rows, mbgen ones are above).
        if (const TSharedPtr<FJsonObject> Erc = LoadJsonObject(Outputs / (BoardId + TEXT(".erc.json"))))
        {
            const TArray<TSharedPtr<FJsonValue>>* Issues = nullptr;
            Erc->TryGetArrayField(TEXT("issues"), Issues);
            int32 Shown = 0;
            if (Issues)
            {
                for (const TSharedPtr<FJsonValue>& V : *Issues)
                {
                    const TSharedPtr<FJsonObject> I = V->AsObject();
                    if (!I.IsValid() || Field(I, TEXT("source")) == TEXT("mbgen")) { continue; }
                    const FString Severity = Field(I, TEXT("severity"));
                    if (Severity == TEXT("error")) { OutErrors += 1; } else if (Severity == TEXT("warning")) { OutWarnings += 1; }
                    const FString Part = Field(I, TEXT("part"));
                    const FString Pin = Field(I, TEXT("pin"));
                    const FString Net = Field(I, TEXT("net"));
                    FString Where = !Pin.IsEmpty() ? Pin : Part;
                    if (!Net.IsEmpty()) { Where += (Where.IsEmpty() ? TEXT("") : TEXT("  ")) + FString::Printf(TEXT("net %s"), *Net); }
                    const TCHAR* Tag = Severity == TEXT("error") ? TEXT("E") : TEXT("W");
                    AddRow(FString::Printf(TEXT("[%s] %s  %s  (%s)\n     %s"), Tag, *Field(I, TEXT("rule")), *Where, *Field(I, TEXT("source")), *Field(I, TEXT("message"))), Part, Pin, Net);
                    Shown += 1;
                }
            }
            AddRow(FString::Printf(TEXT("[i] skidl  boards/%s: %s, %d error(s), %d warning(s) (%d shown)"), *BoardId,
                Erc->GetBoolField(TEXT("ok")) ? TEXT("ok") : TEXT("FAILED"), (int32)Erc->GetNumberField(TEXT("errors")), (int32)Erc->GetNumberField(TEXT("warnings")), Shown), FString(), FString(), FString());
        }
        if (const TSharedPtr<FJsonObject> Par = LoadJsonObject(Outputs / (BoardId + TEXT(".parity.json"))))
        {
            const bool bOk = Par->GetBoolField(TEXT("ok"));
            if (!bOk) { OutErrors += 1; }
            const TArray<TSharedPtr<FJsonValue>>* Unresolved = nullptr;
            Par->TryGetArrayField(TEXT("unresolved_footprints"), Unresolved);
            AddRow(FString::Printf(TEXT("[%s] parity  boards/%s: %s, %d nets checked, %d unresolved footprint(s)"),
                bOk ? TEXT("i") : TEXT("E"), *BoardId, bOk ? TEXT("netlist agrees with the circuit") : TEXT("netlist DISAGREES with the circuit"),
                (int32)Par->GetNumberField(TEXT("nets_checked")), Unresolved ? Unresolved->Num() : 0), FString(), FString(), FString());
        }
        TArray<FString> Sims;
        IFileManager::Get().FindFiles(Sims, *(Outputs / TEXT("sim") / TEXT("*.json")), true, false);
        Sims.Sort();
        for (const FString& SimFile : Sims)
        {
            const TSharedPtr<FJsonObject> Sim = LoadJsonObject(Outputs / TEXT("sim") / SimFile);
            if (!Sim.IsValid()) { continue; }
            const FString Status = Field(Sim, TEXT("status"));
            if (Status == TEXT("fail")) { OutErrors += 1; } else if (Status == TEXT("incomplete")) { OutWarnings += 1; }
            FString MeasText;
            const TSharedPtr<FJsonObject>* Meas = nullptr;
            if (Sim->TryGetObjectField(TEXT("measurements"), Meas) && Meas && Meas->IsValid())
            {
                for (const auto& Pair : (*Meas)->Values)
                {
                    const TSharedPtr<FJsonObject> M = Pair.Value->AsObject();
                    if (!M.IsValid()) { continue; }
                    FString Value = TEXT("—");
                    double V = 0.0;
                    if (M->TryGetNumberField(TEXT("value"), V)) { Value = FString::SanitizeFloat(V); }
                    MeasText += FString::Printf(TEXT("\n       %s = %s  %s"), *Pair.Key, *Value, M->GetBoolField(TEXT("ok")) ? TEXT("ok") : TEXT("OUT"));
                }
            }
            const TCHAR* Tag = Status == TEXT("pass") ? TEXT("i") : (Status == TEXT("fail") ? TEXT("E") : TEXT("W"));
            AddRow(FString::Printf(TEXT("[%s] sim %s  boards/%s: %s — %s%s"), Tag, *Field(Sim, TEXT("scenario_id")), *BoardId, *Status.ToUpper(), *Field(Sim, TEXT("reason")), *MeasText), FString(), FString(), FString());
        }
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
