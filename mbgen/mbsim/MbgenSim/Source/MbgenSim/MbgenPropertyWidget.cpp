#include "MbgenPropertyWidget.h"
#include "MbgenBoardActor.h"
#include "MbgenPackageWidget.h"
#include "EngineUtils.h"
#include "Widgets/SBoxPanel.h"
#include "Widgets/Input/SButton.h"
#include "Widgets/Input/SComboBox.h"
#include "Widgets/Input/SEditableTextBox.h"
#include "Widgets/Text/STextBlock.h"
#include "Dom/JsonObject.h"
#include "Serialization/JsonSerializer.h"
#include "Misc/FileHelper.h"
#include "Misc/Paths.h"
#include "MbgenStore.h"

static TSharedPtr<FJsonObject> LoadJsonObjectFromArray(const FString& Path, const FString& IdKey, const FString& Id)
{
    FString Text;
    if (!FFileHelper::LoadFileToString(Text, *Path)) { return nullptr; }
    TSharedPtr<FJsonValue> Root;
    TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(Text);
    if (!FJsonSerializer::Deserialize(Reader, Root) || !Root.IsValid()) { return nullptr; }
    if (Root->Type == EJson::Array)
    {
        for (const TSharedPtr<FJsonValue>& Item : Root->AsArray())
        {
            const TSharedPtr<FJsonObject> Obj = Item->AsObject();
            if (Obj && Obj->GetStringField(IdKey) == Id) { return Obj; }
        }
        return nullptr;
    }
    return Root->AsObject();
}

void UMbgenPropertyWidget::ShowPart(const FString& Id)
{
    PartId = Id;
    FillSheet();
}

void UMbgenPropertyWidget::FillSheet()
{
    if (!Body.IsValid()) { return; }
    Body->ClearChildren();
    AMbgenBoardActor* Board = AMbgenBoardActor::FindLive(GetWorld());
    if (PartId.IsEmpty() && Board) { PartId = Board->SelectedId; }
    if (PartId.IsEmpty() || PartId == TEXT("pcb") || PartId == TEXT("shield"))
    {
        Body->AddSlot().AutoHeight().Padding(8)
        [ SNew(STextBlock).Text(FText::FromString(TEXT("Select a part."))) ];
        FillBoardSettings(Board);
        return;
    }
    FString Role = PartId;
    FString Edge;
    bool bPinned = false;
    bool bHasSocket = false;
    int32 YawQ = 0;
    if (Board)
    {
        FString DesignText;
        if (FFileHelper::LoadFileToString(DesignText, *Board->DesignFile))
        {
            TSharedPtr<FJsonObject> Design;
            TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(DesignText);
            TSharedPtr<FJsonValue> Root;
            if (FJsonSerializer::Deserialize(Reader, Root) && Root.IsValid() && Root->AsObject())
            {
                Design = Root->AsObject();
                const TArray<TSharedPtr<FJsonValue>>* Ports = nullptr;
                if (Design->TryGetArrayField(TEXT("ports"), Ports))
                {
                    for (const TSharedPtr<FJsonValue>& Item : *Ports)
                    {
                        const TSharedPtr<FJsonObject> P = Item->AsObject();
                        if (!P) { continue; }
                        if (P->GetStringField(TEXT("role")) == TEXT("socket")) { bHasSocket = true; }
                        if (P->GetStringField(TEXT("id")) == PartId)
                        {
                            Role = P->GetStringField(TEXT("role"));
                        }
                    }
                }
                const TArray<TSharedPtr<FJsonValue>>* Places = nullptr;
                if (Design->TryGetArrayField(TEXT("placements"), Places))
                {
                    for (const TSharedPtr<FJsonValue>& Item : *Places)
                    {
                        const TSharedPtr<FJsonObject> P = Item->AsObject();
                        if (P && P->GetStringField(TEXT("id")) == PartId)
                        {
                            Edge = P->GetStringField(TEXT("edge"));
                            bPinned = P->GetBoolField(TEXT("pinned"));
                            double YawV = 0.0;
                            if (P->TryGetNumberField(TEXT("yaw_q"), YawV)) { YawQ = (int32)YawV; }
                            break;
                        }
                    }
                }
            }
        }
    }
    const TSharedPtr<FJsonObject> Lib = LoadJsonObjectFromArray(
        FPaths::ProjectContentDir() / TEXT("Boards/library.json"), TEXT("id"), Role);
    FString Support = TEXT("board");
    FString Domain = TEXT("peripheral");
    FString Lcsc;
    FString PinSpec;
    bool bHatch = false;
    if (Lib)
    {
        Lib->TryGetStringField(TEXT("support"), Support);
        Lib->TryGetStringField(TEXT("domain"), Domain);
        Lib->TryGetStringField(TEXT("lcsc"), Lcsc);
        Lib->TryGetStringField(TEXT("pin_spec"), PinSpec);
        Lib->TryGetBoolField(TEXT("hatch"), bHatch);
    }
    const FString Hatch = bHatch ? TEXT("yes") : TEXT("no");
    FString Labels;
    if (Lib && Lib->HasTypedField<EJson::Array>(TEXT("labels")))
    {
        for (const TSharedPtr<FJsonValue>& L : Lib->GetArrayField(TEXT("labels")))
        {
            if (!Labels.IsEmpty()) { Labels += TEXT("  "); }
            Labels += L->AsString();
        }
    }
    FString PinsNote = TEXT("no pin combo");
    if (Role == TEXT("socket")) { PinsNote = TEXT("unnamed land grid — no named pins"); }
    else if (Role == TEXT("usb_stack") || Role == TEXT("usb_c") || Role == TEXT("esd"))
    {
        PinsNote = TEXT("gap — zero pins");
    }
    else if (PinSpec == TEXT("names_only") && !Lcsc.IsEmpty())
    {
        PinsNote = FString::Printf(TEXT("names-only %s (no pad XY)"), *Lcsc);
    }
    FString Contracts;
    if (Lib && Lib->HasTypedField<EJson::Array>(TEXT("contracts")))
    {
        for (const TSharedPtr<FJsonValue>& C : Lib->GetArrayField(TEXT("contracts")))
        {
            if (!Contracts.IsEmpty()) { Contracts += TEXT("  "); }
            Contracts += C->AsString();
        }
    }
    auto Line = [](const FString& S) -> TSharedRef<SWidget>
    {
        return SNew(STextBlock).Text(FText::FromString(S)).AutoWrapText(true);
    };
    Body->AddSlot().AutoHeight().Padding(8, 2) [ Line(FString::Printf(TEXT("id  %s"), *PartId)) ];
    Body->AddSlot().AutoHeight().Padding(8, 2) [ Line(FString::Printf(TEXT("role  %s"), *Role)) ];
    Body->AddSlot().AutoHeight().Padding(8, 2) [ Line(FString::Printf(TEXT("support  %s  (read-only)"), *Support)) ];
    Body->AddSlot().AutoHeight().Padding(8, 2) [ Line(FString::Printf(TEXT("domain  %s  (read-only)"), *Domain)) ];
    InterfaceOptions.Reset();
    InterfaceOptions.Add(MakeShared<FString>(Role));
    Body->AddSlot().AutoHeight().Padding(8, 2)
    [
        SNew(SHorizontalBox)
        + SHorizontalBox::Slot().AutoWidth().VAlign(VAlign_Center).Padding(0, 0, 8, 0)
        [ SNew(STextBlock).Text(FText::FromString(TEXT("interface"))) ]
        + SHorizontalBox::Slot().FillWidth(1.f)
        [
            SNew(SComboBox<TSharedPtr<FString>>)
            .OptionsSource(&InterfaceOptions)
            .InitiallySelectedItem(InterfaceOptions[0])
            .OnGenerateWidget_Lambda([](TSharedPtr<FString> Item)
            {
                return SNew(STextBlock).Text(FText::FromString(Item.IsValid() ? *Item : FString()));
            })
            .OnSelectionChanged_Lambda([this, Role](TSharedPtr<FString> Item, ESelectInfo::Type)
            {
                if (Item.IsValid() && *Item != Role) { SetKey(TEXT("interface"), *Item); }
            })
            [
                SNew(STextBlock).Text(FText::FromString(Role))
            ]
        ]
    ];
    Body->AddSlot().AutoHeight().Padding(8, 2) [ Line(FString::Printf(TEXT("edge  %s  pinned %s"), *Edge, bPinned ? TEXT("yes") : TEXT("no"))) ];
    int64 XUm = 0;
    int64 YUm = 0;
    if (Board) { Board->PartXyUm(PartId, XUm, YUm); }
    const FString Unit = FMbgenStore::UnitSuffix();
    auto CommitXy = [this](const FText&, ETextCommit::Type Commit)
    {
        if (Commit != ETextCommit::OnEnter && Commit != ETextCommit::OnUserMovedFocus) { return; }
        AMbgenBoardActor* Live = AMbgenBoardActor::FindLive(GetWorld());
        if (!Live || !XBox.IsValid() || !YBox.IsValid()) { return; }
        const int64 NX = FMbgenStore::ToUm(FCString::Atod(*XBox->GetText().ToString()));
        const int64 NY = FMbgenStore::ToUm(FCString::Atod(*YBox->GetText().ToString()));
        Live->ApplyGestureJson(FString::Printf(TEXT("{\"op\":\"place\",\"id\":\"%s\",\"x_um\":%lld,\"y_um\":%lld}"), *PartId, NX, NY));
    };
    XBox = SNew(SEditableTextBox).Text(FText::FromString(FString::Printf(TEXT("%.4f"), FMbgenStore::FromUm(XUm)))).OnTextCommitted_Lambda(CommitXy);
    YBox = SNew(SEditableTextBox).Text(FText::FromString(FString::Printf(TEXT("%.4f"), FMbgenStore::FromUm(YUm)))).OnTextCommitted_Lambda(CommitXy);
    Body->AddSlot().AutoHeight().Padding(8, 2)
    [
        SNew(SHorizontalBox)
        + SHorizontalBox::Slot().AutoWidth().VAlign(VAlign_Center).Padding(0, 0, 6, 0)
        [ SNew(STextBlock).Text(FText::FromString(TEXT("X"))) ]
        + SHorizontalBox::Slot().FillWidth(1.f) [ XBox.ToSharedRef() ]
        + SHorizontalBox::Slot().AutoWidth().VAlign(VAlign_Center).Padding(8, 0, 6, 0)
        [ SNew(STextBlock).Text(FText::FromString(TEXT("Y"))) ]
        + SHorizontalBox::Slot().FillWidth(1.f) [ YBox.ToSharedRef() ]
        + SHorizontalBox::Slot().AutoWidth().VAlign(VAlign_Center).Padding(8, 0, 0, 0)
        [ SNew(STextBlock).Text(FText::FromString(Unit + TEXT(" from 0,0"))) ]
    ];
    Body->AddSlot().AutoHeight().Padding(8, 2)
    [
        SNew(SHorizontalBox)
        + SHorizontalBox::Slot().AutoWidth().VAlign(VAlign_Center).Padding(0, 0, 8, 0)
        [ SNew(STextBlock).Text(FText::FromString(FString::Printf(TEXT("yaw  %d°"), (YawQ % 4) * 90))) ]
        + SHorizontalBox::Slot().AutoWidth()
        [
            SNew(SButton)
            .OnClicked_Lambda([this]()
            {
                AMbgenBoardActor* Live = AMbgenBoardActor::FindLive(GetWorld());
                if (Live && AMbgenBoardActor::IsEditablePart(PartId))
                {
                    Live->SelectedId = PartId;
                    Live->TurnSelected();
                }
                FillSheet();
                return FReply::Handled();
            })
            [ SNew(STextBlock).Text(FText::FromString(TEXT("Turn 90°"))) ]
        ]
    ];
    Body->AddSlot().AutoHeight().Padding(8, 2) [ Line(FString::Printf(TEXT("hatch  %s"), *Hatch)) ];
    if (!Lcsc.IsEmpty())
    {
        Body->AddSlot().AutoHeight().Padding(8, 2) [ Line(FString::Printf(TEXT("lcsc  %s"), *Lcsc)) ];
    }
    if (!Labels.IsEmpty())
    {
        Body->AddSlot().AutoHeight().Padding(8, 2) [ Line(Labels) ];
    }
    Body->AddSlot().AutoHeight().Padding(8, 2) [ Line(PinsNote) ];
    if (!Contracts.IsEmpty())
    {
        Body->AddSlot().AutoHeight().Padding(8, 2)
        [ Line(FString::Printf(TEXT("contracts  %s"), *Contracts)) ];
    }
    if (Role == TEXT("socket") || !bHasSocket)
    {
        FillBoardSettings(Board);
    }
    Body->AddSlot().AutoHeight().Padding(8, 6)
    [
        SNew(SButton)
        .OnClicked_Lambda([this]() { AutoConnect(); return FReply::Handled(); })
        [
            SNew(STextBlock).Text(FText::FromString(TEXT("Auto-connect (CEM / SATA rails only)")))
        ]
    ];
    UE_LOG(LogTemp, Display, TEXT("mbgen properties %s role=%s support=%s"), *PartId, *Role, *Support);
}

void UMbgenPropertyWidget::FillBoardSettings(AMbgenBoardActor* Board)
{
    if (!Body.IsValid()) { return; }
    auto Line = [](const FString& S) -> TSharedRef<SWidget>
    {
        return SNew(STextBlock).Text(FText::FromString(S)).AutoWrapText(true);
    };
    FString PackageId = TEXT("cv64a6_imafdc_sv39");
    FString Hotkey = TEXT("DEL");
    FString Timeout = TEXT("2000");
    FString Product = TEXT("desktop");
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
                Design = Root->AsObject();
                const TSharedPtr<FJsonObject>* Settings = nullptr;
                if (Design->TryGetObjectField(TEXT("settings"), Settings) && Settings)
                {
                    PackageId = (*Settings)->GetStringField(TEXT("package_id"));
                    FString H, T, P;
                    if ((*Settings)->TryGetStringField(TEXT("hotkey"), H) && !H.IsEmpty()) { Hotkey = H; }
                    if ((*Settings)->TryGetStringField(TEXT("timeout_ms"), T) && !T.IsEmpty()) { Timeout = T; }
                    else if ((*Settings)->HasField(TEXT("timeout_ms")))
                    {
                        Timeout = FString::Printf(TEXT("%lld"), (int64)(*Settings)->GetNumberField(TEXT("timeout_ms")));
                    }
                    if ((*Settings)->TryGetStringField(TEXT("product"), P) && !P.IsEmpty()) { Product = P; }
                }
            }
        }
    }
    const FString PackagesPath = FPaths::ProjectContentDir() / TEXT("Boards/packages.json");
    PackageOptions.Reset();
    TSharedPtr<FString> SelectedPkg;
    {
        FString PkgText;
        if (FFileHelper::LoadFileToString(PkgText, *PackagesPath))
        {
            TSharedPtr<FJsonValue> PkgRoot;
            TSharedRef<TJsonReader<>> PkgReader = TJsonReaderFactory<>::Create(PkgText);
            if (FJsonSerializer::Deserialize(PkgReader, PkgRoot) && PkgRoot.IsValid() && PkgRoot->Type == EJson::Array)
            {
                for (const TSharedPtr<FJsonValue>& Item : PkgRoot->AsArray())
                {
                    const TSharedPtr<FJsonObject> Obj = Item->AsObject();
                    if (!Obj) { continue; }
                    const FString Id = Obj->GetStringField(TEXT("id"));
                    TSharedPtr<FString> Opt = MakeShared<FString>(Id);
                    PackageOptions.Add(Opt);
                    if (Id == PackageId) { SelectedPkg = Opt; }
                }
            }
        }
    }
    if (!SelectedPkg.IsValid() && PackageOptions.Num() > 0) { SelectedPkg = PackageOptions[0]; }
    if (PackageOptions.Num() > 0)
    {
        Body->AddSlot().AutoHeight().Padding(8, 8, 8, 2)
        [ Line(TEXT("package  (SetProperty package_id)")) ];
        Body->AddSlot().AutoHeight().Padding(8, 2)
        [
            SNew(SComboBox<TSharedPtr<FString>>)
            .OptionsSource(&PackageOptions)
            .InitiallySelectedItem(SelectedPkg)
            .OnGenerateWidget_Lambda([](TSharedPtr<FString> Item)
            {
                return SNew(STextBlock).Text(FText::FromString(Item.IsValid() ? *Item : FString()));
            })
            .OnSelectionChanged_Lambda([this, PackageId](TSharedPtr<FString> Item, ESelectInfo::Type)
            {
                if (Item.IsValid() && *Item != PackageId) { SetKey(TEXT("package_id"), *Item); }
            })
            [
                SNew(STextBlock).Text(FText::FromString(PackageId))
            ]
        ];
    }
    const TSharedPtr<FJsonObject> Card = LoadJsonObjectFromArray(PackagesPath, TEXT("id"), PackageId);
    if (Card)
    {
        Body->AddSlot().AutoHeight().Padding(8, 2)
        [ Line(FString::Printf(TEXT("isa  %s  xlen %d"), *Card->GetStringField(TEXT("isa")), (int32)Card->GetNumberField(TEXT("xlen")))) ];
        Body->AddSlot().AutoHeight().Padding(8, 2)
        [ Line(FString::Printf(TEXT("cores  %d  threads  %d  axi  %d"),
            (int32)Card->GetNumberField(TEXT("cores")),
            (int32)Card->GetNumberField(TEXT("threads")),
            (int32)Card->GetNumberField(TEXT("axi_bits")))) ];
        Body->AddSlot().AutoHeight().Padding(8, 2)
        [ Line(FString::Printf(TEXT("ooo  %s  l2  %s  l3  %s  ai  %s"),
            Card->GetBoolField(TEXT("ooo")) ? TEXT("yes") : TEXT("no"),
            Card->GetBoolField(TEXT("l2")) ? TEXT("yes") : TEXT("no"),
            Card->GetBoolField(TEXT("l3")) ? TEXT("yes") : TEXT("no"),
            Card->GetBoolField(TEXT("ai")) ? TEXT("yes") : TEXT("no"))) ];
    }
    Body->AddSlot().AutoHeight().Padding(8, 8, 8, 2)
    [ Line(TEXT("firmware witness  (no CSRs)")) ];
    auto Witness = [this](const FString& Key, const FString& Value) -> TSharedRef<SWidget>
    {
        return SNew(SHorizontalBox)
            + SHorizontalBox::Slot().AutoWidth().VAlign(VAlign_Center).Padding(0, 0, 8, 0)
            [ SNew(STextBlock).Text(FText::FromString(Key)) ]
            + SHorizontalBox::Slot().FillWidth(1.f)
            [
                SNew(SEditableTextBox)
                .Text(FText::FromString(Value))
                .OnTextCommitted_Lambda([this, Key](const FText& Text, ETextCommit::Type)
                {
                    SetKey(Key, Text.ToString());
                })
            ];
    };
    Body->AddSlot().AutoHeight().Padding(8, 2) [ Witness(TEXT("hotkey"), Hotkey) ];
    Body->AddSlot().AutoHeight().Padding(8, 2) [ Witness(TEXT("timeout_ms"), Timeout) ];
    Body->AddSlot().AutoHeight().Padding(8, 2) [ Witness(TEXT("product"), Product) ];
    FString FwText;
    FString FwPath = FPaths::ProjectContentDir() / TEXT("Boards/firmware.json");
    if (!FPaths::FileExists(FwPath))
    {
        FwPath = FPaths::ProjectContentDir() / TEXT("Boards/product/firmware.json");
    }
    if (FFileHelper::LoadFileToString(FwText, *FwPath))
    {
        TSharedPtr<FJsonValue> FwRoot;
        TSharedRef<TJsonReader<>> FwReader = TJsonReaderFactory<>::Create(FwText);
        TSharedPtr<FJsonObject> Fw;
        if (FJsonSerializer::Deserialize(FwReader, FwRoot) && FwRoot.IsValid() && FwRoot->AsObject())
        {
            Fw = FwRoot->AsObject();
            const TArray<TSharedPtr<FJsonValue>>* Peripherals = nullptr;
            if (Fw->TryGetArrayField(TEXT("peripherals"), Peripherals) && Peripherals)
            {
                Body->AddSlot().AutoHeight().Padding(8, 8, 8, 2)
                [ Line(TEXT("peripherals  (base stays empty)")) ];
                for (const TSharedPtr<FJsonValue>& Item : *Peripherals)
                {
                    const TSharedPtr<FJsonObject> P = Item->AsObject();
                    if (!P) { continue; }
                    Body->AddSlot().AutoHeight().Padding(8, 2)
                    [ Line(FString::Printf(TEXT("%s  %s  base %s"),
                        *P->GetStringField(TEXT("id")),
                        *P->GetStringField(TEXT("class")),
                        *P->GetStringField(TEXT("base")))) ];
                }
            }
        }
    }
}

void UMbgenPropertyWidget::RefreshPose()
{
    if (!XBox.IsValid() || !YBox.IsValid() || PartId.IsEmpty()) { return; }
    if (XBox->HasKeyboardFocus() || YBox->HasKeyboardFocus()) { return; }
    AMbgenBoardActor* Board = AMbgenBoardActor::FindLive(GetWorld());
    int64 XUm = 0;
    int64 YUm = 0;
    if (Board) { Board->PartXyUm(PartId, XUm, YUm); }
    XBox->SetText(FText::FromString(FString::Printf(TEXT("%.4f"), FMbgenStore::FromUm(XUm))));
    YBox->SetText(FText::FromString(FString::Printf(TEXT("%.4f"), FMbgenStore::FromUm(YUm))));
}

void UMbgenPropertyWidget::AutoConnect()
{
    AMbgenBoardActor* Board = AMbgenBoardActor::FindLive(GetWorld());
    if (!Board || PartId.IsEmpty()) { return; }
    Board->ApplyGestureJson(FString::Printf(TEXT("{\"op\":\"auto_connect\",\"id\":\"%s\"}"), *PartId));
}

void UMbgenPropertyWidget::SetKey(const FString& Key, const FString& Value)
{
    AMbgenBoardActor* Board = AMbgenBoardActor::FindLive(GetWorld());
    if (!Board) { return; }
    FString Host = PartId;
    if (Host.IsEmpty() || !AMbgenBoardActor::IsEditablePart(Host)) { Host = Board->PropertyHostId(); }
    if (Host.IsEmpty()) { return; }
    FString Escaped;
    for (const TCHAR C : Value)
    {
        if (C == TCHAR('\\') || C == TCHAR('"')) { Escaped += TCHAR('\\'); }
        Escaped += C;
    }
    UE_LOG(LogTemp, Display, TEXT("mbgen set_property %s %s"), *Key, *Value);
    Board->ApplyGestureJson(FString::Printf(
        TEXT("{\"op\":\"set_property\",\"id\":\"%s\",\"key\":\"%s\",\"value\":\"%s\"}"),
        *Host, *Key, *Escaped));
    if (Key == TEXT("package_id")) { UMbgenPackageWidget::RefreshAll(); }
    FillSheet();
}

TSharedRef<SWidget> UMbgenPropertyWidget::RebuildWidget()
{
    Body = SNew(SVerticalBox);
    FillSheet();
    Header = SNew(STextBlock).Text(FText::FromString(TEXT("Properties — drag the title. Support and domain are read-only. USB and the socket have no pin combo.")));
    TSharedRef<SVerticalBox> Root = SNew(SVerticalBox)
        + SVerticalBox::Slot().AutoHeight().Padding(8)
        [ Header.ToSharedRef() ]
        + SVerticalBox::Slot().FillHeight(1.f)
        [ Body.ToSharedRef() ];
    return Root;
}

FReply UMbgenPropertyWidget::NativeOnMouseButtonDown(const FGeometry& Geo, const FPointerEvent& Event)
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

FReply UMbgenPropertyWidget::NativeOnMouseMove(const FGeometry& Geo, const FPointerEvent& Event)
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

FReply UMbgenPropertyWidget::NativeOnMouseButtonUp(const FGeometry& Geo, const FPointerEvent& Event)
{
    bDragging = false;
    return FReply::Handled().ReleaseMouseCapture();
}
