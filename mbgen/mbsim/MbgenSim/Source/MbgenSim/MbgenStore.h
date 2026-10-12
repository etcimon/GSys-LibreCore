#pragma once
#include "CoreMinimal.h"

struct FMbgenStore
{
    static void Open();
    static void Close();
    static float MouseSens();
    static float ClampWheel(float Notches);
    static float ZoomDistance(float Dist, float Notches);
    static FString LengthUnit();
    static void SetLengthUnit(const FString& Unit);
    static void SetMouseSens(float Sens);
    static double FromUm(int64 Um);
    static int64 ToUm(double Value);
    static FString UnitSuffix();
    static void PushUndo(const FString& DesignJson, const FString& Op);
    static bool HasUndoLog();
    static bool Undo(FString& OutJson);
    static bool Redo(FString& OutJson);
    static bool SaveBoard(const FString& DesignJson);
    static bool LoadBoard(FString& OutJson);
    static void SetClipboard(const FString& Json);
    static bool GetClipboard(FString& OutJson);
};
