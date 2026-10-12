#pragma once
#include "CoreMinimal.h"
#include "Blueprint/UserWidget.h"
#include "MbgenChrome.generated.h"

struct FMbgenChrome
{
    static void Start();
    static void Stop();
    static void Tick();
    static TSharedRef<class SWidget> MakeBar();
    static void ToggleSettings();
    static void ToggleProps();
    static void Undo();
    static void Redo();
    static void Save();
    static void Open();
    static void Copy();
    static void Paste();
};

UCLASS()
class MBGENSIM_API UMbgenChromeWidget : public UUserWidget
{
    GENERATED_BODY()
public:
    virtual TSharedRef<SWidget> RebuildWidget() override;
};
