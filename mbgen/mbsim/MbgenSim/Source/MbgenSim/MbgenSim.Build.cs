using UnrealBuildTool;
public class MbgenSim : ModuleRules
{
    public MbgenSim(ReadOnlyTargetRules Target) : base(Target)
    {
        PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;
        PublicDependencyModuleNames.AddRange(new string[] {
            "Core", "CoreUObject", "Engine", "InputCore", "ProceduralMeshComponent", "Json", "JsonUtilities", "UMG", "Slate", "SlateCore", "SQLiteCore"
        });
        if (Target.bBuildEditor)
        {
            PrivateDependencyModuleNames.AddRange(new string[] { "UnrealEd", "LevelEditor" });
        }
    }
}
