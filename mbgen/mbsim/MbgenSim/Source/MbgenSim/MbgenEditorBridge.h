#pragma once

struct FMbgenEditorBridge
{
    static void Start();
    static void Stop();
    static void FrameOrbit(const FVector& WorldPivot);
    static void DiagnoseNav();
};
