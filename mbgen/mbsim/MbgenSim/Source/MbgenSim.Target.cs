using UnrealBuildTool;
using System.Collections.Generic;
public class MbgenSimTarget : TargetRules
{
    public MbgenSimTarget(TargetInfo Target) : base(Target)
    {
        Type = TargetType.Game;
        DefaultBuildSettings = BuildSettingsVersion.V7;
        IncludeOrderVersion = EngineIncludeOrderVersion.Unreal5_8;
        ExtraModuleNames.Add("MbgenSim");
    }
}
