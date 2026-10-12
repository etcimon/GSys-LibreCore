#include "MbgenLibraryWidget.h"
#include "MbgenBoardActor.h"
#include "EngineUtils.h"
#include "ImageUtils.h"
#include "Widgets/SBoxPanel.h"
#include "Widgets/Input/SButton.h"
#include "Widgets/Input/SEditableTextBox.h"
#include "Widgets/Text/STextBlock.h"
#include "Widgets/Layout/SScrollBox.h"
#include "Widgets/Layout/SBox.h"
#include "Widgets/Layout/SBorder.h"
#include "Widgets/Images/SImage.h"
#include "Styling/SlateBrush.h"
#include "Dom/JsonObject.h"
#include "Serialization/JsonSerializer.h"
#include "Misc/FileHelper.h"
#include "Misc/Paths.h"
#include "Framework/Application/SlateApplication.h"
#include "UObject/UObjectIterator.h"
#if WITH_EDITOR
#include "Editor.h"
#endif

static FString GRoleDrag;
static FVector2D GRoleDragStart = FVector2D::ZeroVector;
static bool GRoleDragMoved = false;

static FString JsonStr(const TSharedPtr<FJsonObject>& Obj, const TCHAR* Field)
{
    FString Out;
    if (Obj.IsValid() && Obj->TryGetStringField(Field, Out)) { return Out; }
    return FString();
}

void UMbgenLibraryWidget::BeginRoleDrag(const FString& Role)
{
    GRoleDrag = Role;
    GRoleDragStart = FSlateApplication::Get().GetCursorPos();
    GRoleDragMoved = false;
}

void UMbgenLibraryWidget::NoteRoleDragMove(const FVector2D& Pos)
{
    if (GRoleDrag.IsEmpty()) { return; }
    if (FVector2D::Distance(Pos, GRoleDragStart) > 8.f) { GRoleDragMoved = true; }
}

bool UMbgenLibraryWidget::TakeRoleDrop(FString& OutRole)
{
    if (GRoleDrag.IsEmpty() || !GRoleDragMoved) { return false; }
    OutRole = GRoleDrag;
    GRoleDrag.Reset();
    GRoleDragMoved = false;
    return true;
}

void UMbgenLibraryWidget::CancelRoleDrag()
{
    GRoleDrag.Reset();
    GRoleDragMoved = false;
}

bool UMbgenLibraryWidget::RoleDragMoved()
{
    return GRoleDragMoved;
}

bool UMbgenLibraryWidget::IsRoleDrag()
{
    return !GRoleDrag.IsEmpty();
}

static bool GThumbsDone = false;
static bool GThumbsForce = false;

void UMbgenLibraryWidget::ReloadThumbs()
{
    EnsureThumbs();
    FillList();
}

void UMbgenLibraryWidget::InvalidateThumbs()
{
    GThumbsDone = false;
    GThumbsForce = true;
    for (TObjectIterator<UMbgenLibraryWidget> It; It; ++It)
    {
        if (IsValid(*It)) { It->ReloadThumbs(); }
    }
}

void UMbgenLibraryWidget::RefreshOpenLists()
{
    for (TObjectIterator<UMbgenLibraryWidget> It; It; ++It)
    {
        if (IsValid(*It)) { It->FillList(); }
    }
}

void UMbgenLibraryWidget::EnsureThumbs()
{
    if (GThumbsDone) { return; }
    GThumbsDone = true;
#if WITH_EDITOR
    if (GEditor)
    {
        const TCHAR* Cmd = GThumbsForce
            ? TEXT("py import mbgen_materials; mbgen_materials.capture_library_thumbs(True)")
            : TEXT("py import mbgen_materials; mbgen_materials.capture_library_thumbs()");
        GThumbsForce = false;
        GEditor->Exec(nullptr, Cmd);
        UE_LOG(LogTemp, Display, TEXT("mbgen library thumbs first-open"));
    }
#endif
}

static FString LetterFor(const FString& Id)
{
    TArray<FString> Parts;
    Id.ParseIntoArray(Parts, TEXT("_"), true);
    FString Out;
    for (const FString& Part : Parts)
    {
        if (Part.IsEmpty()) { continue; }
        Out += Part.Left(1).ToUpper();
        if (Out.Len() >= 2) { break; }
    }
    return Out.IsEmpty() ? TEXT("?") : Out;
}

void UMbgenLibraryWidget::LoadRows()
{
    Rows.Reset();
    FString Text;
    const FString Path = FPaths::ProjectContentDir() / TEXT("Boards/library.json");
    if (!FFileHelper::LoadFileToString(Text, *Path)) { return; }
    TSharedPtr<FJsonValue> Root;
    TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(Text);
    if (!FJsonSerializer::Deserialize(Reader, Root) || !Root.IsValid() || Root->Type != EJson::Array) { return; }
    for (const TSharedPtr<FJsonValue>& Item : Root->AsArray())
    {
        const TSharedPtr<FJsonObject> Obj = Item->AsObject();
        if (!Obj) { continue; }
        FMbgenLibraryRow Row;
        Row.Id = JsonStr(Obj, TEXT("id"));
        Row.Role = JsonStr(Obj, TEXT("role"));
        Row.Support = JsonStr(Obj, TEXT("support"));
        Row.Domain = JsonStr(Obj, TEXT("domain"));
        Row.Vendor = JsonStr(Obj, TEXT("vendor_id"));
        Row.Mpn = JsonStr(Obj, TEXT("mpn"));
        Row.Lcsc = JsonStr(Obj, TEXT("lcsc"));
        Row.Note = JsonStr(Obj, TEXT("note"));
        bool bHatch = false;
        Obj->TryGetBoolField(TEXT("hatch"), bHatch);
        Row.bHatch = bHatch;
        if (Obj->HasTypedField<EJson::Array>(TEXT("labels")))
        {
            for (const TSharedPtr<FJsonValue>& Label : Obj->GetArrayField(TEXT("labels")))
            {
                Row.Labels.Add(Label->AsString());
            }
        }
        if (Obj->HasTypedField<EJson::Array>(TEXT("contracts")))
        {
            for (const TSharedPtr<FJsonValue>& C : Obj->GetArrayField(TEXT("contracts")))
            {
                Row.Contracts.Add(C->AsString());
            }
        }
        Rows.Add(MoveTemp(Row));
    }
}

bool UMbgenLibraryWidget::RowMatches(const FMbgenLibraryRow& Row) const
{
    if (Filter.IsEmpty()) { return true; }
    auto Has = [this](const FString& S) { return S.Contains(Filter, ESearchCase::IgnoreCase); };
    if (Has(Row.Id) || Has(Row.Role) || Has(Row.Support) || Has(Row.Domain) || Has(Row.Vendor) || Has(Row.Mpn) || Has(Row.Lcsc) || Has(Row.Note))
    {
        return true;
    }
    for (const FString& Label : Row.Labels)
    {
        if (Has(Label)) { return true; }
    }
    for (const FString& Contract : Row.Contracts)
    {
        if (Has(Contract)) { return true; }
    }
    return false;
}

TSharedRef<SWidget> UMbgenLibraryWidget::MakeThumb(const FMbgenLibraryRow& Row, bool& bUsedFile)
{
    bUsedFile = false;
    const FString Path = FPaths::ProjectSavedDir() / TEXT("Thumbnails") / (Row.Id + TEXT(".png"));
    if (FPaths::FileExists(Path))
    {
        if (UTexture2D* Tex = FImageUtils::ImportFileAsTexture2D(Path))
        {
            LoadedThumbs.Add(Tex);
            TSharedPtr<FSlateBrush> Brush = MakeShared<FSlateBrush>();
            Brush->SetResourceObject(Tex);
            Brush->ImageSize = FVector2D(40.f, 40.f);
            BrushKeep.Add(Brush);
            bUsedFile = true;
            return SNew(SBox).WidthOverride(40.f).HeightOverride(40.f)
            [
                SNew(SImage).Image(Brush.Get())
            ];
        }
    }
    const FLinearColor Bg = Row.bHatch
        ? FLinearColor(0.16f, 0.16f, 0.12f)
        : FLinearColor(0.18f, 0.24f, 0.32f);
    return SNew(SBox).WidthOverride(40.f).HeightOverride(40.f)
    [
        SNew(SBorder)
        .BorderBackgroundColor(Bg)
        .Padding(2.f)
        .HAlign(HAlign_Center)
        .VAlign(VAlign_Center)
        [
            SNew(STextBlock)
            .Text(FText::FromString(LetterFor(Row.Id)))
            .ColorAndOpacity(Row.bHatch ? FLinearColor(0.55f, 0.58f, 0.42f) : FLinearColor(0.85f, 0.88f, 0.92f))
        ]
    ];
}

void UMbgenLibraryWidget::FillList()
{
    if (!List.IsValid()) { return; }
    List->ClearChildren();
    LoadedThumbs.Reset();
    BrushKeep.Reset();
    int32 Shown = 0;
    int32 Thumbs = 0;
    int32 Miss = 0;
    for (const FMbgenLibraryRow& Row : Rows)
    {
        if (!RowMatches(Row)) { continue; }
        Shown += 1;
        bool bUsedFile = false;
        TSharedRef<SWidget> Thumb = MakeThumb(Row, bUsedFile);
        if (bUsedFile) { Thumbs += 1; }
        else { Miss += 1; }
        FString Extra;
        if (!Row.Lcsc.IsEmpty()) { Extra += TEXT("  ") + Row.Lcsc; }
        for (const FString& Label : Row.Labels)
        {
            Extra += TEXT("  ") + Label;
        }
        for (const FString& Contract : Row.Contracts)
        {
            Extra += TEXT("  ") + Contract;
        }
        const FString Line = FString::Printf(TEXT("%s  %s  %s%s"), *Row.Role, *Row.Support, *Row.Domain, *Extra);
        const FString Role = Row.Role;
        List->AddSlot().Padding(4, 2)
        [
            SNew(SButton)
            .OnPressed_Lambda([Role]() { UMbgenLibraryWidget::BeginRoleDrag(Role); })
            .OnClicked_Lambda([this, Role]()
            {
                if (!UMbgenLibraryWidget::RoleDragMoved()) { AddRole(Role); }
                UMbgenLibraryWidget::CancelRoleDrag();
                return FReply::Handled();
            })
            [
                SNew(SHorizontalBox)
                + SHorizontalBox::Slot().AutoWidth().VAlign(VAlign_Center).Padding(0, 0, 8, 0)
                [ Thumb ]
                + SHorizontalBox::Slot().FillWidth(1.f).VAlign(VAlign_Center)
                [
                    SNew(STextBlock).Text(FText::FromString(Line)).AutoWrapText(true)
                ]
            ]
        ];
    }
    UE_LOG(LogTemp, Display, TEXT("mbgen library rows=%d thumbs=%d miss=%d"), Shown, Thumbs, Miss);
}

void UMbgenLibraryWidget::OnSearch(const FText& Text)
{
    Filter = Text.ToString();
    FillList();
}

void UMbgenLibraryWidget::AddRole(const FString& Role)
{
    AMbgenBoardActor* Board = AMbgenBoardActor::FindLive(GetWorld());
    if (!Board) { return; }
    UE_LOG(LogTemp, Display, TEXT("mbgen add %s"), *Role);
    Board->AddRole(Role);
}

TSharedRef<SWidget> UMbgenLibraryWidget::RebuildWidget()
{
    AMbgenBoardActor* Board = AMbgenBoardActor::FindLive(GetWorld());
    if (Board) { Board->RefreshLibraryFile(); }
    EnsureThumbs();
    LoadRows();
    List = SNew(SScrollBox);
    FillList();
    Header = SNew(STextBlock).Text(FText::FromString(TEXT("Parts — click a row to Add. Drag a row onto the PCB top to Place. Search role / MPN / LCSC / P12V.")));
    return SNew(SVerticalBox)
        + SVerticalBox::Slot().AutoHeight().Padding(8)
        [
            Header.ToSharedRef()
        ]
        + SVerticalBox::Slot().AutoHeight().Padding(8, 0, 8, 8)
        [
            SNew(SEditableTextBox)
            .HintText(FText::FromString(TEXT("usb_c  C426228  P12V  wifi")))
            .OnTextChanged_Lambda([this](const FText& Text) { OnSearch(Text); })
        ]
        + SVerticalBox::Slot().FillHeight(1.f).Padding(4)
        [
            List.ToSharedRef()
        ];
}

FReply UMbgenLibraryWidget::NativeOnMouseButtonDown(const FGeometry& Geo, const FPointerEvent& Event)
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

FReply UMbgenLibraryWidget::NativeOnMouseMove(const FGeometry& Geo, const FPointerEvent& Event)
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

FReply UMbgenLibraryWidget::NativeOnMouseButtonUp(const FGeometry& Geo, const FPointerEvent& Event)
{
    bDragging = false;
    return FReply::Handled().ReleaseMouseCapture();
}
