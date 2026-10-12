#include "MbgenStore.h"
#include "MbgenSettings.h"
#include "SQLiteDatabase.h"
#include "SQLitePreparedStatement.h"
#include "Misc/Paths.h"
#include "HAL/FileManager.h"
#include "Misc/DateTime.h"

static FSQLiteDatabase GDb;
static int32 GUndoSeq = 0;
static int32 GUndoHead = 0;

static FString DbPath()
{
    return FPaths::ConvertRelativePathToFull(FPaths::ProjectSavedDir() / TEXT("mbgen.sqlite"));
}

static UMbgenSettings* MutableSettings()
{
    return GetMutableDefault<UMbgenSettings>();
}

static void PutSetting(const TCHAR* Key, const FString& Value)
{
    if (!GDb.IsValid()) { return; }
    FSQLitePreparedStatement Stmt = GDb.PrepareStatement(TEXT("INSERT OR REPLACE INTO settings(key, value) VALUES(?1, ?2)"));
    Stmt.SetBindingValueByIndex(1, Key);
    Stmt.SetBindingValueByIndex(2, Value);
    Stmt.Execute();
}

static void LoadSettingsFromDb()
{
    UMbgenSettings* S = MutableSettings();
    if (!S || !GDb.IsValid()) { return; }
    bool bSensLaw = false;
    GDb.Execute(TEXT("SELECT key, value FROM settings"), [&](const FSQLitePreparedStatement& Row)
    {
        FString Key, Value;
        Row.GetColumnValueByIndex(0, Key);
        Row.GetColumnValueByIndex(1, Value);
        if (Key == TEXT("unit") && !Value.IsEmpty()) { S->LengthUnit = Value; }
        if (Key == TEXT("sens"))
        {
            S->MouseSensitivity = FMath::Clamp(FCString::Atof(*Value), 0.05f, 2.f);
        }
        if (Key == TEXT("sens_law") && Value == TEXT("catia")) { bSensLaw = true; }
        return ESQLitePreparedStatementExecuteRowResult::Continue;
    });
    if (!bSensLaw)
    {
        S->MouseSensitivity = 0.25f;
        PutSetting(TEXT("sens"), TEXT("0.25"));
        PutSetting(TEXT("sens_law"), TEXT("catia"));
    }
    S->SaveConfig();
}

void FMbgenStore::Open()
{
    IFileManager::Get().MakeDirectory(*FPaths::ProjectSavedDir(), true);
    if (GDb.IsValid()) { return; }
    if (!GDb.Open(*DbPath(), ESQLiteDatabaseOpenMode::ReadWriteCreate))
    {
        UE_LOG(LogTemp, Warning, TEXT("mbgen sqlite open failed %s"), *DbPath());
        return;
    }
    GDb.Execute(TEXT("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)"));
    GDb.Execute(TEXT("CREATE TABLE IF NOT EXISTS saves (name TEXT PRIMARY KEY, json TEXT NOT NULL, saved_at INTEGER)"));
    GDb.Execute(TEXT("CREATE TABLE IF NOT EXISTS log (id INTEGER PRIMARY KEY AUTOINCREMENT, seq INTEGER NOT NULL, op TEXT NOT NULL, json TEXT NOT NULL, created_at INTEGER)"));
    GDb.Execute(TEXT("CREATE TABLE IF NOT EXISTS clip (id INTEGER PRIMARY KEY CHECK(id=1), json TEXT NOT NULL)"));
    GDb.Execute(TEXT("SELECT MAX(seq) FROM log"), [&](const FSQLitePreparedStatement& Row)
    {
        int32 MaxSeq = 0;
        Row.GetColumnValueByIndex(0, MaxSeq);
        GUndoHead = MaxSeq;
        GUndoSeq = MaxSeq;
        return ESQLitePreparedStatementExecuteRowResult::Stop;
    });
    LoadSettingsFromDb();
    UE_LOG(LogTemp, Display, TEXT("mbgen sqlite %s seq=%d"), *DbPath(), GUndoSeq);
}

void FMbgenStore::Close()
{
    GDb.Close();
}

float FMbgenStore::MouseSens()
{
    const UMbgenSettings* S = GetDefault<UMbgenSettings>();
    return FMath::Clamp(S ? S->MouseSensitivity : 0.25f, 0.05f, 2.f);
}

FString FMbgenStore::LengthUnit()
{
    const UMbgenSettings* S = GetDefault<UMbgenSettings>();
    const FString U = S ? S->LengthUnit : TEXT("mm");
    if (U == TEXT("um") || U == TEXT("mm") || U == TEXT("cm") || U == TEXT("m") || U == TEXT("mil") || U == TEXT("inch"))
    {
        return U;
    }
    return TEXT("mm");
}

void FMbgenStore::SetLengthUnit(const FString& Unit)
{
    UMbgenSettings* S = MutableSettings();
    if (!S) { return; }
    S->LengthUnit = Unit;
    S->SaveConfig();
    PutSetting(TEXT("unit"), Unit);
}

void FMbgenStore::SetMouseSens(float Sens)
{
    UMbgenSettings* S = MutableSettings();
    if (!S) { return; }
    S->MouseSensitivity = FMath::Clamp(Sens, 0.05f, 2.f);
    S->SaveConfig();
    PutSetting(TEXT("sens"), FString::SanitizeFloat(S->MouseSensitivity));
}

float FMbgenStore::ClampWheel(float Notches)
{
    return FMath::Clamp(Notches, -1.f, 1.f);
}

float FMbgenStore::ZoomDistance(float Dist, float Notches)
{
    const float N = ClampWheel(Notches) * MouseSens();
    return FMath::Clamp(Dist / FMath::Pow(1.04f, N), 20.f, 8000.f);
}

double FMbgenStore::FromUm(int64 Um)
{
    const FString U = LengthUnit();
    if (U == TEXT("um")) { return double(Um); }
    if (U == TEXT("cm")) { return double(Um) / 10000.0; }
    if (U == TEXT("m")) { return double(Um) / 1000000.0; }
    if (U == TEXT("inch")) { return double(Um) / 25400.0; }
    if (U == TEXT("mil")) { return double(Um) / 25.4; }
    return double(Um) / 1000.0;
}

int64 FMbgenStore::ToUm(double Value)
{
    const FString U = LengthUnit();
    double Um = Value * 1000.0;
    if (U == TEXT("um")) { Um = Value; }
    else if (U == TEXT("cm")) { Um = Value * 10000.0; }
    else if (U == TEXT("m")) { Um = Value * 1000000.0; }
    else if (U == TEXT("inch")) { Um = Value * 25400.0; }
    else if (U == TEXT("mil")) { Um = Value * 25.4; }
    return FMath::RoundToInt64(Um);
}

FString FMbgenStore::UnitSuffix()
{
    const FString U = LengthUnit();
    if (U == TEXT("um")) { return TEXT("µm"); }
    if (U == TEXT("inch")) { return TEXT("in"); }
    return U;
}

bool FMbgenStore::HasUndoLog()
{
    return GUndoSeq >= 1;
}

void FMbgenStore::PushUndo(const FString& DesignJson, const FString& Op)
{
    if (!GDb.IsValid() || DesignJson.IsEmpty()) { return; }
    GDb.Execute(*FString::Printf(TEXT("DELETE FROM log WHERE seq > %d"), GUndoSeq));
    GUndoSeq += 1;
    GUndoHead = GUndoSeq;
    FSQLitePreparedStatement Stmt = GDb.PrepareStatement(TEXT("INSERT INTO log(seq, op, json, created_at) VALUES(?1, ?2, ?3, ?4)"));
    Stmt.SetBindingValueByIndex(1, GUndoSeq);
    Stmt.SetBindingValueByIndex(2, Op);
    Stmt.SetBindingValueByIndex(3, DesignJson);
    Stmt.SetBindingValueByIndex(4, (int64)FDateTime::UtcNow().ToUnixTimestamp());
    Stmt.Execute();
}

static bool LoadSeq(int32 Seq, FString& OutJson)
{
    if (!GDb.IsValid() || Seq < 1) { return false; }
    bool bOk = false;
    FSQLitePreparedStatement Stmt = GDb.PrepareStatement(TEXT("SELECT json FROM log WHERE seq = ?1 LIMIT 1"));
    Stmt.SetBindingValueByIndex(1, Seq);
    if (Stmt.Step() == ESQLitePreparedStatementStepResult::Row)
    {
        bOk = Stmt.GetColumnValueByIndex(0, OutJson);
    }
    return bOk && !OutJson.IsEmpty();
}

bool FMbgenStore::Undo(FString& OutJson)
{
    if (GUndoSeq <= 1) { return false; }
    if (!LoadSeq(GUndoSeq - 1, OutJson)) { return false; }
    GUndoSeq -= 1;
    return true;
}

bool FMbgenStore::Redo(FString& OutJson)
{
    if (GUndoSeq >= GUndoHead) { return false; }
    if (!LoadSeq(GUndoSeq + 1, OutJson)) { return false; }
    GUndoSeq += 1;
    return true;
}

bool FMbgenStore::SaveBoard(const FString& DesignJson)
{
    if (!GDb.IsValid() || DesignJson.IsEmpty()) { return false; }
    FSQLitePreparedStatement Stmt = GDb.PrepareStatement(TEXT("INSERT OR REPLACE INTO saves(name, json, saved_at) VALUES('board', ?1, ?2)"));
    Stmt.SetBindingValueByIndex(1, DesignJson);
    Stmt.SetBindingValueByIndex(2, (int64)FDateTime::UtcNow().ToUnixTimestamp());
    const bool bOk = Stmt.Execute();
    if (bOk) { UE_LOG(LogTemp, Display, TEXT("mbgen sqlite saved")); }
    return bOk;
}

bool FMbgenStore::LoadBoard(FString& OutJson)
{
    if (!GDb.IsValid()) { return false; }
    bool bOk = false;
    GDb.Execute(TEXT("SELECT json FROM saves WHERE name = 'board' LIMIT 1"), [&](const FSQLitePreparedStatement& Row)
    {
        bOk = Row.GetColumnValueByIndex(0, OutJson);
        return ESQLitePreparedStatementExecuteRowResult::Stop;
    });
    return bOk && !OutJson.IsEmpty();
}

void FMbgenStore::SetClipboard(const FString& Json)
{
    if (!GDb.IsValid() || Json.IsEmpty()) { return; }
    FSQLitePreparedStatement Stmt = GDb.PrepareStatement(TEXT("INSERT OR REPLACE INTO clip(id, json) VALUES(1, ?1)"));
    Stmt.SetBindingValueByIndex(1, Json);
    Stmt.Execute();
}

bool FMbgenStore::GetClipboard(FString& OutJson)
{
    if (!GDb.IsValid()) { return false; }
    bool bOk = false;
    GDb.Execute(TEXT("SELECT json FROM clip WHERE id = 1"), [&](const FSQLitePreparedStatement& Row)
    {
        bOk = Row.GetColumnValueByIndex(0, OutJson);
        return ESQLitePreparedStatementExecuteRowResult::Stop;
    });
    return bOk && !OutJson.IsEmpty();
}
