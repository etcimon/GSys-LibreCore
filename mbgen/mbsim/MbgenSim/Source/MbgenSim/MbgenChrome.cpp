#include "MbgenChrome.h"
#include "MbgenStore.h"
#include "MbgenBoardActor.h"
#include "MbgenPropertyWidget.h"
#include "MbgenSettings.h"
#include "Widgets/SBoxPanel.h"
#include "Widgets/Input/SButton.h"
#include "Widgets/Input/SComboBox.h"
#include "Widgets/Input/SEditableTextBox.h"
#include "Widgets/Text/STextBlock.h"
#include "Widgets/SWindow.h"
#include "Styling/CoreStyle.h"
#include "Framework/Application/SlateApplication.h"
#include "Misc/FileHelper.h"
#include "Serialization/JsonSerializer.h"
#include "Dom/JsonObject.h"

#if WITH_EDITOR
#include "Editor.h"
#include "LevelEditor.h"
#include "SLevelViewport.h"
#include "LevelEditorViewport.h"
#endif

static TWeakPtr<SWindow> GChromeWin;
static TWeakPtr<SWindow> GSettingsWin;
static TWeakPtr<SWindow> GPropsWin;
static TWeakObjectPtr<UMbgenPropertyWidget> GChromeProps;
static TArray<TSharedPtr<FString>> GUnitOptions;
static FVector2D GChromeScreen = FVector2D(20.f, 12.f);

static AMbgenBoardActor* LiveBoard()
{
    return AMbgenBoardActor::FindLive(nullptr);
}

static void CloseWin(TWeakPtr<SWindow>& Win)
{
    if (TSharedPtr<SWindow> Existing = Win.Pin()) { Existing->RequestDestroyWindow(); }
    Win.Reset();
}

static FVector2D BelowChrome(float OffsetX)
{
    return GChromeScreen + FVector2D(OffsetX, 36.f);
}

static void ApplyDesignJson(const FString& Json, const TCHAR* Label)
{
    AMbgenBoardActor* Board = LiveBoard();
    if (!Board || Json.IsEmpty()) { return; }
    FFileHelper::SaveStringToFile(Json, *Board->DesignFile);
    Board->ReloadDesignFromDisk();
    if (FCString::Stricmp(Label, TEXT("open")) == 0) { Board->FrameOrbit(); }
    UE_LOG(LogTemp, Display, TEXT("mbgen %s"), Label);
}

static TSharedRef<SWidget> IconBtn(const FString& Label, TFunction<void()> OnClick)
{
    return SNew(SButton)
        .ContentPadding(FMargin(6.f, 4.f))
        .OnClicked_Lambda([OnClick]() { OnClick(); return FReply::Handled(); })
        [
            SNew(STextBlock).Text(FText::FromString(Label))
        ];
}

TSharedRef<SWidget> FMbgenChrome::MakeBar()
{
    return SNew(SHorizontalBox)
        + SHorizontalBox::Slot().AutoWidth() [ IconBtn(TEXT("Settings"), []() { ToggleSettings(); }) ]
        + SHorizontalBox::Slot().AutoWidth() [ IconBtn(TEXT("Props"), []() { ToggleProps(); }) ]
        + SHorizontalBox::Slot().AutoWidth() [ IconBtn(TEXT("Undo"), []() { Undo(); }) ]
        + SHorizontalBox::Slot().AutoWidth() [ IconBtn(TEXT("Redo"), []() { Redo(); }) ]
        + SHorizontalBox::Slot().AutoWidth() [ IconBtn(TEXT("Save"), []() { Save(); }) ]
        + SHorizontalBox::Slot().AutoWidth() [ IconBtn(TEXT("Open"), []() { Open(); }) ]
        + SHorizontalBox::Slot().AutoWidth() [ IconBtn(TEXT("Copy"), []() { Copy(); }) ]
        + SHorizontalBox::Slot().AutoWidth() [ IconBtn(TEXT("Paste"), []() { Paste(); }) ];
}

void FMbgenChrome::ToggleSettings()
{
    if (GSettingsWin.IsValid()) { CloseWin(GSettingsWin); return; }
    if (GUnitOptions.Num() == 0)
    {
        for (const TCHAR* U : { TEXT("um"), TEXT("mm"), TEXT("cm"), TEXT("m"), TEXT("mil"), TEXT("inch") })
        {
            GUnitOptions.Add(MakeShared<FString>(U));
        }
    }
    TSharedPtr<FString> CurrentUnit;
    const FString Unit = FMbgenStore::LengthUnit();
    for (const TSharedPtr<FString>& Opt : GUnitOptions)
    {
        if (Opt.IsValid() && *Opt == Unit) { CurrentUnit = Opt; break; }
    }
    if (!CurrentUnit.IsValid()) { CurrentUnit = GUnitOptions[1]; }
    TSharedRef<SWindow> Win = SNew(SWindow)
        .Title(FText::FromString(TEXT("Settings")))
        .ClientSize(FVector2D(280.f, 140.f))
        .SupportsMaximize(false)
        .SupportsMinimize(false)
        .ScreenPosition(BelowChrome(0.f));
    Win->SetContent(
        SNew(SVerticalBox)
        + SVerticalBox::Slot().AutoHeight().Padding(8, 6)
        [
            SNew(SHorizontalBox)
            + SHorizontalBox::Slot().AutoWidth().VAlign(VAlign_Center).Padding(0, 0, 8, 0)
            [ SNew(STextBlock).Text(FText::FromString(TEXT("units"))) ]
            + SHorizontalBox::Slot().FillWidth(1.f)
            [
                SNew(SComboBox<TSharedPtr<FString>>)
                .OptionsSource(&GUnitOptions)
                .InitiallySelectedItem(CurrentUnit)
                .OnGenerateWidget_Lambda([](TSharedPtr<FString> Item)
                {
                    return SNew(STextBlock).Text(FText::FromString(Item.IsValid() ? *Item : FString()));
                })
                .OnSelectionChanged_Lambda([](TSharedPtr<FString> Item, ESelectInfo::Type)
                {
                    if (Item.IsValid())
                    {
                        FMbgenStore::SetLengthUnit(*Item);
                        if (AMbgenBoardActor* B = LiveBoard()) { B->RefreshOpenSheets(); }
                    }
                })
                [ SNew(STextBlock).Text(FText::FromString(Unit)) ]
            ]
        ]
        + SVerticalBox::Slot().AutoHeight().Padding(8, 6)
        [
            SNew(SHorizontalBox)
            + SHorizontalBox::Slot().AutoWidth().VAlign(VAlign_Center).Padding(0, 0, 8, 0)
            [ SNew(STextBlock).Text(FText::FromString(TEXT("mouse sens"))) ]
            + SHorizontalBox::Slot().FillWidth(1.f)
            [
                SNew(SEditableTextBox)
                .Text(FText::FromString(FString::SanitizeFloat(FMbgenStore::MouseSens())))
                .OnTextCommitted_Lambda([](const FText& Text, ETextCommit::Type)
                {
                    FMbgenStore::SetMouseSens(FCString::Atof(*Text.ToString()));
                })
            ]
        ]
        + SVerticalBox::Slot().AutoHeight().Padding(8, 6)
        [ SNew(STextBlock).AutoWrapText(true).Text(FText::FromString(TEXT("Sens scales look, orbit, pan, and zoom. Cursor Place and arrow keys stay on the board millimetre (1 mm, Shift 0.1 mm)."))) ]
    );
    GSettingsWin = Win;
    FSlateApplication::Get().AddWindow(Win);
}

void FMbgenChrome::ToggleProps()
{
    if (GPropsWin.IsValid())
    {
        CloseWin(GPropsWin);
        GChromeProps.Reset();
        return;
    }
    AMbgenBoardActor* Board = LiveBoard();
    UWorld* World = Board ? Board->GetWorld() : nullptr;
#if WITH_EDITOR
    if (!World && GEditor) { World = GEditor->GetEditorWorldContext().World(); }
#endif
    if (!World) { return; }
    UMbgenPropertyWidget* Widget = CreateWidget<UMbgenPropertyWidget>(World, UMbgenPropertyWidget::StaticClass());
    if (!Widget) { return; }
    if (Board) { Widget->ShowPart(Board->SelectedId); }
    TSharedRef<SWindow> Win = SNew(SWindow)
        .Title(FText::FromString(TEXT("Properties")))
        .ClientSize(FVector2D(420.f, 560.f))
        .SupportsMaximize(false)
        .ScreenPosition(BelowChrome(70.f));
    Win->SetContent(Widget->TakeWidget());
    GPropsWin = Win;
    GChromeProps = Widget;
    FSlateApplication::Get().AddWindow(Win);
}

void FMbgenChrome::Undo()
{
    FString Json;
    if (FMbgenStore::Undo(Json)) { ApplyDesignJson(Json, TEXT("undo")); }
}

void FMbgenChrome::Redo()
{
    FString Json;
    if (FMbgenStore::Redo(Json)) { ApplyDesignJson(Json, TEXT("redo")); }
}

void FMbgenChrome::Save()
{
    AMbgenBoardActor* Board = LiveBoard();
    if (!Board) { return; }
    FString Json;
    if (FFileHelper::LoadFileToString(Json, *Board->DesignFile))
    {
        FMbgenStore::SaveBoard(Json);
    }
}

void FMbgenChrome::Open()
{
    FString Json;
    if (FMbgenStore::LoadBoard(Json)) { ApplyDesignJson(Json, TEXT("open")); }
}

void FMbgenChrome::Copy()
{
    AMbgenBoardActor* Board = LiveBoard();
    if (Board) { Board->CopyPartToStore(); }
}

void FMbgenChrome::Paste()
{
    AMbgenBoardActor* Board = LiveBoard();
    if (Board) { Board->PastePartFromStore(); }
}

void FMbgenChrome::Start()
{
    FMbgenStore::Open();
    if (GChromeWin.IsValid()) { return; }
    TSharedRef<SWindow> Win = SNew(SWindow)
        .CreateTitleBar(false)
        .SizingRule(ESizingRule::Autosized)
        .IsTopmostWindow(true)
        .HasCloseButton(false)
        .SupportsMaximize(false)
        .SupportsMinimize(false)
        .ScreenPosition(GChromeScreen);
    Win->SetContent(SNew(SBorder).Padding(4.f) [ MakeBar() ]);
    GChromeWin = Win;
    FSlateApplication::Get().AddWindow(Win, false);
}

void FMbgenChrome::Stop()
{
    CloseWin(GChromeWin);
    CloseWin(GSettingsWin);
    CloseWin(GPropsWin);
    GChromeProps.Reset();
    FMbgenStore::Close();
}

void FMbgenChrome::Tick()
{
#if WITH_EDITOR
    if (!GChromeWin.IsValid() || !GEditor) { return; }
    FVector2D Pos(20.f, 12.f);
    if (FModuleManager::Get().IsModuleLoaded("LevelEditor"))
    {
        FLevelEditorModule& Module = FModuleManager::GetModuleChecked<FLevelEditorModule>("LevelEditor");
        TSharedPtr<SLevelViewport> Viewport = Module.GetFirstActiveLevelViewport();
        if (Viewport.IsValid())
        {
            const FGeometry Geo = Viewport->GetCachedGeometry();
            const FVector2D Local = Geo.GetLocalSize();
            Pos = Geo.LocalToAbsolute(FVector2D(Local.X - 8.f, 8.f));
        }
    }
    if (TSharedPtr<SWindow> Win = GChromeWin.Pin())
    {
        const FVector2D Size = Win->GetSizeInScreen();
        if (Size.X > 1.f) { Pos.X -= Size.X; }
        else { Pos.X -= 420.f; }
        GChromeScreen = Pos;
        Win->MoveWindowTo(Pos);
    }
    else
    {
        GChromeScreen = Pos;
    }
#endif
}

TSharedRef<SWidget> UMbgenChromeWidget::RebuildWidget()
{
    return FMbgenChrome::MakeBar();
}
