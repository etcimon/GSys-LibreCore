# Runs when the Unreal editor opens. One lit material per slot, with the
# textures mbgen wrote under Content/Textures baked onto the samplers.
# A shared material-instance texture parameter stayed on DefaultTexture, so
# each slot owns its own samplers. Name plaques stay unlit so the text
# does not pick up the metal shading.

import unreal

# emissive is a floor under the lit response. Data maps are R roughness, G metallic.
SLOTS = {
    "solder_mask": {
        "metal": 0.0, "rough": 0.55, "emissive": 0.38,
        "base": "/Game/Textures/T_SolderMask",
        "data": "/Game/Textures/T_SolderData",
        "normal": "/Game/Textures/T_SolderNormal",
    },
    "metal": {
        "metal": 1.0, "rough": 0.34, "emissive": 0.16,
        "base": "/Game/Textures/T_Metal",
        "data": "/Game/Textures/T_MetalData",
        "normal": "/Game/Textures/T_MetalNormal",
    },
    "plastic": {
        "metal": 0.0, "rough": 0.48, "emissive": 0.36,
        "base": "/Game/Textures/T_Plastic",
        "data": "/Game/Textures/T_PlasticData",
        "normal": "/Game/Textures/T_PlasticNormal",
    },
    "gold": {
        "metal": 1.0, "rough": 0.28, "emissive": 0.18,
        "base": "/Game/Textures/T_Gold",
        "data": "/Game/Textures/T_GoldData",
        "normal": "/Game/Textures/T_GoldNormal",
    },
    "ceramic": {
        "metal": 0.0, "rough": 0.62, "emissive": 0.34,
        "base": "/Game/Textures/T_Ceramic",
        "data": "/Game/Textures/T_CeramicData",
        "normal": "/Game/Textures/T_CeramicNormal",
    },
    "ghost": {
        "metal": 0.05, "rough": 0.80, "emissive": 0.7,
        "base": "/Game/Textures/T_Ghost",
        "data": "",
        "normal": "",
    },
    "cavity": {
        "metal": 0.0, "rough": 0.92, "emissive": 0.03,
        "base": "/Game/Textures/T_Cavity",
        "data": "",
        "normal": "",
    },
    "led_green": {
        "metal": 0.0, "rough": 0.22, "emissive": 0.9,
        "base": "/Game/Textures/T_LedGreen",
        "data": "",
        "normal": "",
    },
    "led_amber": {
        "metal": 0.0, "rough": 0.22, "emissive": 0.9,
        "base": "/Game/Textures/T_LedAmber",
        "data": "",
        "normal": "",
    },
    "pin": {
        "metal": 0.8, "rough": 0.32, "emissive": 0.18,
        "base": "/Game/Textures/T_PinGold",
        "data": "",
        "normal": "",
    },
}

COLOR_MAPS = ("T_SolderMask", "T_Metal", "T_Plastic", "T_Gold", "T_Ceramic", "T_Ghost", "T_Cavity", "T_LedGreen", "T_LedAmber", "T_PinGold")
DATA_MAPS = ("T_SolderData", "T_MetalData", "T_PlasticData", "T_GoldData", "T_CeramicData")
NORMAL_MAPS = ("T_SolderNormal", "T_MetalNormal", "T_PlasticNormal", "T_GoldNormal", "T_CeramicNormal")


def _set(obj, prop, value):
    try:
        obj.set_editor_property(prop, value)
        return True
    except Exception as exc:
        unreal.log_warning(f"mbgen property {prop} kept: {exc}")
        return False


def _editor_world():
    return unreal.get_editor_subsystem(unreal.UnrealEditorSubsystem).get_editor_world()


def _level_actors():
    return list(unreal.get_editor_subsystem(unreal.EditorActorSubsystem).get_all_level_actors())


def _spawn_actor(cls, loc, rot=None):
    if rot is None:
        rot = unreal.Rotator(0.0, 0.0, 0.0)
    return unreal.get_editor_subsystem(unreal.EditorActorSubsystem).spawn_actor_from_class(cls, loc, rot)


def _destroy_actor(actor):
    return unreal.get_editor_subsystem(unreal.EditorActorSubsystem).destroy_actor(actor)


def _save_level():
    return unreal.get_editor_subsystem(unreal.LevelEditorSubsystem).save_current_level()


def _load_map(path):
    return unreal.get_editor_subsystem(unreal.LevelEditorSubsystem).load_level(path)


def _new_level(path):
    return unreal.get_editor_subsystem(unreal.LevelEditorSubsystem).new_level(path)


def _clear_material(mat):
    if not mat:
        return
    mel = unreal.MaterialEditingLibrary
    mel.delete_all_material_expressions(mat)
    try:
        leftover = list(mat.get_editor_property("expressions") or [])
    except Exception:
        leftover = []
    for node in leftover:
        try:
            mel.delete_material_expression(mat, node)
        except Exception:
            pass


def _fresh_material(asset_name, folder):
    path = f"{folder}/{asset_name}"
    tools = unreal.AssetToolsHelpers.get_asset_tools()
    mat = None
    if unreal.EditorAssetLibrary.does_asset_exist(path):
        mat = unreal.EditorAssetLibrary.load_asset(path)
        _clear_material(mat)
    if mat is None:
        mat = tools.create_asset(asset_name, folder, unreal.Material, unreal.MaterialFactoryNew())
    return mat


def _const(mat, name, value, x, y):
    mel = unreal.MaterialEditingLibrary
    node = mel.create_material_expression(mat, unreal.MaterialExpressionScalarParameter, x, y)
    node.set_editor_property("parameter_name", name)
    node.set_editor_property("default_value", float(value))
    return node


def _sample(mat, path, x, y, kind):
    mel = unreal.MaterialEditingLibrary
    node = mel.create_material_expression(mat, unreal.MaterialExpressionTextureSample, x, y)
    tex = unreal.EditorAssetLibrary.load_asset(path) if path else None
    if tex:
        node.set_editor_property("texture", tex)
    sampler = {
        "color": unreal.MaterialSamplerType.SAMPLERTYPE_COLOR,
        "linear": unreal.MaterialSamplerType.SAMPLERTYPE_MASKS,
        "normal": unreal.MaterialSamplerType.SAMPLERTYPE_NORMAL,
    }[kind]
    _set(node, "sampler_type", sampler)
    return node, tex


def _out(node, pin, prop):
    unreal.MaterialEditingLibrary.connect_material_property(node, pin, prop)


def _node(mat, kind, x, y):
    return unreal.MaterialEditingLibrary.create_material_expression(mat, kind, x, y)


def _join(src, src_pin, dst, dst_pin):
    ok = unreal.MaterialEditingLibrary.connect_material_expressions(src, src_pin, dst, dst_pin)
    if not ok:
        unreal.log_warning(
            f"mbgen material connect {src.get_class().get_name()} -> {dst.get_class().get_name()}.{dst_pin or 'default'} failed"
        )
    return ok


def _up_facing(mat):
    """1 on the top and bottom faces, 0 on the vertical faces. Emissive then shows the form."""
    normal = _node(mat, unreal.MaterialExpressionVertexNormalWS, -980, 40)
    up = _node(mat, unreal.MaterialExpressionConstant3Vector, -980, 180)
    up.set_editor_property("constant", unreal.LinearColor(0.0, 0.0, 1.0, 1.0))
    dot = _node(mat, unreal.MaterialExpressionDotProduct, -760, 100)
    _join(normal, "", dot, "A")
    _join(up, "", dot, "B")
    # (N·up)^2 is 1 on top and bottom, 0 on vertical faces. Abs pin names
    # shorten to empty in UE 5.8 and fail to connect.
    facing = _node(mat, unreal.MaterialExpressionMultiply, -580, 100)
    _join(dot, "", facing, "A")
    _join(dot, "", facing, "B")
    return facing


def _shaped_color(mat, name, base):
    """Vertical faces fall off. The board edge becomes bare laminate instead of stretched mask."""
    facing = _up_facing(mat)
    if name == "solder_mask":
        laminate = _node(mat, unreal.MaterialExpressionConstant3Vector, -760, -40)
        laminate.set_editor_property("constant", unreal.LinearColor(0.45, 0.32, 0.16, 1.0))
        mixed = _node(mat, unreal.MaterialExpressionLinearInterpolate, -280, -80)
        _join(laminate, "", mixed, "A")
        _join(base, "RGB", mixed, "B")
        _join(facing, "", mixed, "Alpha")
        return mixed
    side = _const(mat, "SideShade", 0.85 if name == "pin" else (0.72 if name == "gold" else 0.5), -760, 40)
    top = _const(mat, "TopShade", 1.0, -760, 140)
    shade = _node(mat, unreal.MaterialExpressionLinearInterpolate, -480, 80)
    _join(side, "", shade, "A")
    _join(top, "", shade, "B")
    _join(facing, "", shade, "Alpha")
    mixed = _node(mat, unreal.MaterialExpressionMultiply, -240, -20)
    _join(base, "RGB", mixed, "A")
    _join(shade, "", mixed, "B")
    return mixed


def _lit_slot(name, spec):
    path = f"/Game/Materials/MSlot_{name}"
    mel = unreal.MaterialEditingLibrary
    mat = _fresh_material(f"MSlot_{name}", "/Game/Materials")
    if not mat:
        unreal.log_error(f"mbgen material {name} missing")
        return
    _set(mat, "shading_model", unreal.MaterialShadingModel.MSM_DEFAULT_LIT)
    _set(mat, "two_sided", True)
    base, tex = _sample(mat, spec["base"], -560, -160, "color")
    color = _shaped_color(mat, name, base)
    _out(color, "", unreal.MaterialProperty.MP_BASE_COLOR)
    scale = _const(mat, "EmissiveFloor", spec["emissive"], -560, 80)
    mul = mel.create_material_expression(mat, unreal.MaterialExpressionMultiply, -80, 40)
    mel.connect_material_expressions(color, "", mul, "A")
    mel.connect_material_expressions(scale, "", mul, "B")
    _out(mul, "", unreal.MaterialProperty.MP_EMISSIVE_COLOR)
    if spec["data"]:
        data, _ = _sample(mat, spec["data"], -560, 220, "linear")
        _out(data, "R", unreal.MaterialProperty.MP_ROUGHNESS)
        _out(data, "G", unreal.MaterialProperty.MP_METALLIC)
    else:
        _out(_const(mat, "Roughness", spec["rough"], -280, 240), "", unreal.MaterialProperty.MP_ROUGHNESS)
        _out(_const(mat, "Metallic", spec["metal"], -280, 360), "", unreal.MaterialProperty.MP_METALLIC)
    if spec["normal"]:
        normal, _ = _sample(mat, spec["normal"], -560, 460, "normal")
        _out(normal, "RGB", unreal.MaterialProperty.MP_NORMAL)
    mel.recompile_material(mat)
    unreal.EditorAssetLibrary.save_asset(path)
    unreal.log(f"mbgen material {name} lit texture={tex.get_name() if tex else 'none'}")


def _unlit(asset, tex_path):
    path = f"/Game/Materials/{asset}"
    mel = unreal.MaterialEditingLibrary
    mat = _fresh_material(asset, "/Game/Materials")
    if not mat:
        unreal.log_error(f"mbgen material {asset} missing")
        return False
    _set(mat, "shading_model", unreal.MaterialShadingModel.MSM_UNLIT)
    _set(mat, "two_sided", True)
    sample, tex = _sample(mat, tex_path, -300, 0, "color")
    _out(sample, "RGB", unreal.MaterialProperty.MP_BASE_COLOR)
    _out(sample, "RGB", unreal.MaterialProperty.MP_EMISSIVE_COLOR)
    mel.recompile_material(mat)
    unreal.EditorAssetLibrary.save_asset(path)
    return tex is not None


def refresh_labels():
    _label_materials()


def _label_materials():
    import os
    import subprocess
    content = unreal.Paths.convert_relative_path_to_full(unreal.Paths.project_content_dir())
    venv = r"E:\cva6\build-platform\workspace\tooling\python-venv\Scripts\python.exe"
    painter = content + "Python/paint_labels.py"
    if os.path.isfile(venv) and os.path.isfile(painter):
        subprocess.run([venv, painter], check=False)
    folder = content + "Textures/Labels/"
    if not os.path.isdir(folder):
        unreal.log_warning("mbgen labels folder missing")
        return
    tools = unreal.AssetToolsHelpers.get_asset_tools()
    count = 0
    for name in os.listdir(folder):
        if not name.startswith("L_") or not name.endswith(".png"):
            continue
        ident = name[2:-4]
        task = unreal.AssetImportTask()
        task.set_editor_property("filename", folder + name)
        task.set_editor_property("destination_path", "/Game/Textures/Labels")
        task.set_editor_property("destination_name", f"L_{ident}")
        task.set_editor_property("replace_existing", True)
        task.set_editor_property("automated", True)
        task.set_editor_property("save", True)
        tools.import_asset_tasks([task])
        if _unlit(f"MLabel_{ident}", f"/Game/Textures/Labels/L_{ident}"):
            count += 1
    unreal.log(f"mbgen labels {count}")


def _capture_board():
    """Write Saved/mbgen-product.png. Leave the capture on the default exposure; a manual bias crushed it."""
    world = _editor_world()
    rt = unreal.RenderingLibrary.create_render_target2d(
        world, 1280, 720, unreal.TextureRenderTargetFormat.RTF_RGBA8, unreal.LinearColor(0.02, 0.02, 0.025, 1.0)
    )
    bodies = _scene_bodies()
    aim = bodies.get("pcb") or unreal.Vector(0.0, 0.0, 0.0)
    eye = _vadd(aim, -210.0, -370.0, 312.0)
    rot = unreal.MathLibrary.find_look_at_rotation(eye, aim)
    cap = _spawn_actor(unreal.SceneCapture2D, eye, rot)
    comp = cap.capture_component2d
    comp.set_editor_property("texture_target", rt)
    comp.set_editor_property("capture_source", unreal.SceneCaptureSource.SCS_FINAL_COLOR_LDR)
    comp.set_editor_property("capture_every_frame", False)
    comp.set_editor_property("fov_angle", 55.0)
    _set(comp, "always_persist_rendering_state", True)
    comp.capture_scene()
    comp.capture_scene()
    comp.capture_scene()
    saved = unreal.Paths.project_saved_dir()
    unreal.RenderingLibrary.export_render_target(world, rt, saved, "mbgen-product.png")

    def _shot(name, origin, aim_off, eye_off, fov):
        if origin is None:
            return
        shot_aim = _vadd(origin, aim_off[0], aim_off[1], aim_off[2])
        shot_eye = _vadd(origin, eye_off[0], eye_off[1], eye_off[2])
        cap.set_actor_location(shot_eye, False, False)
        cap.set_actor_rotation(unreal.MathLibrary.find_look_at_rotation(shot_eye, shot_aim), False)
        comp.set_editor_property("fov_angle", fov)
        comp.capture_scene()
        comp.capture_scene()
        unreal.RenderingLibrary.export_render_target(world, rt, saved, name)

    # Offsets are the Mini-ITX product look relative to each scene body.
    _, roles = _scene_index()
    _shot("mbgen-pcie-pins.png", roles.get("pcie_slot"), (0.0, 0.0, 13.8), (-39.0, -32.8, 55.8), 20.0)
    _shot("mbgen-dimm-pins.png", roles.get("dimm"), (0.0, 0.0, 10.3), (38.0, -25.0, 58.3), 22.0)
    _shot("mbgen-nvme-pins.png", roles.get("nvme_m2"), (0.0, 82.0, 0.8), (34.0, 114.0, 16.8), 16.0)
    _shot("mbgen-sata-pins.png", roles.get("sata"), (-11.0, -8.1, 8.8), (-40.0, -30.1, 33.8), 18.0)
    _shot("mbgen-hdmi-pins.png", roles.get("hdmi"), (0.05, -9.0, 21.8), (0.05, -34.0, 32.8), 14.0)
    _shot("mbgen-lan-pins.png", roles.get("gbe_magjack"), (0.05, -9.0, 21.8), (0.05, -34.0, 32.8), 14.0)
    _shot("mbgen-socket-pads.png", roles.get("socket"), (0.0, 0.0, 4.8), (20.0, -25.8, 32.8), 16.0)
    _shot("mbgen-fp-pins.png", roles.get("front_panel"), (0.0, 0.0, 10.8), (22.0, 20.0, 28.8), 16.0)
    _shot("mbgen-spi-leads.png", roles.get("spi_flash"), (0.0, 0.0, 0.3), (32.0, -32.0, 26.3), 22.0)
    _shot("mbgen-nvme-leads.png", roles.get("nvme_m2"), (0.0, 9.0, 2.8), (47.0, 29.0, 28.8), 20.0)
    _shot("mbgen-bat-contacts.png", roles.get("rtc_battery"), (0.0, 0.0, 4.8), (28.0, -22.8, 22.8), 16.0)
    _shot("mbgen-io-shield.png", roles.get("shield"), (-94.0, 0.4, -25.7), (-94.0, 178.4, 2.4), 40.0)
    _shot("mbgen-product-rear.png", roles.get("pcb"), (0.0, 80.0, 18.4), (110.0, 310.0, 258.4), 50.0)
    _shot("mbgen-io-front.png", roles.get("gbe_magjack"), (9.8, 0.0, 0.8), (-10.3, -104.0, 6.8), 40.0)
    _shot("mbgen-lan-mouth.png", roles.get("gbe_magjack"), (0.05, 19.0, 0.0), (0.05, 44.0, 4.8), 14.0)
    _shot("mbgen-hdmi-mouth.png", roles.get("hdmi"), (0.05, 19.0, 0.0), (0.05, 44.0, 4.8), 14.0)
    _shot("mbgen-usb-mouth.png", roles.get("usb_stack"), (0.05, 16.0, 0.0), (0.05, 86.0, 18.8), 30.0)
    _shot("mbgen-decap.png", roles.get("decap") or bodies.get("c0"), (0.0, 0.0, 0.0), (14.8, -22.0, 12.3), 18.0)
    _shot("mbgen-esd.png", roles.get("esd"), (0.0, 0.0, 0.0), (22.0, -20.0, 20.0), 18.0)
    _destroy_actor(cap)
    unreal.log("mbgen board capture wrote")
    try:
        import json
        import os
        product = os.path.join(unreal.Paths.project_content_dir(), "Boards", "product")
        nets_n = 0
        paths_n = 0
        open_n = 0
        unroutable_n = 0
        nets_path = os.path.join(product, "nets.json")
        paths_path = os.path.join(product, "paths.json")
        errors_path = os.path.join(product, "errors.json")
        if os.path.isfile(nets_path):
            with open(nets_path, "r", encoding="utf-8") as handle:
                nets = json.load(handle)
            nets_n = len(nets) if isinstance(nets, list) else 0
        if os.path.isfile(paths_path):
            with open(paths_path, "r", encoding="utf-8") as handle:
                paths = json.load(handle)
            paths_n = len(paths) if isinstance(paths, list) else 0
        if os.path.isfile(errors_path):
            with open(errors_path, "r", encoding="utf-8") as handle:
                errors = json.load(handle)
            if isinstance(errors, list):
                open_n = sum(1 for err in errors if isinstance(err, dict) and err.get("kind") == "OpenRequired")
                unroutable_n = sum(1 for err in errors if isinstance(err, dict) and err.get("kind") == "Unroutable")
        unreal.log(f"mbgen nets={nets_n} open={open_n} unroutable={unroutable_n} paths={paths_n} um")
    except Exception as exc:
        unreal.log_warning(f"mbgen nets log skipped: {exc}")


def capture_library_thumbs(force=False, only_role=None):
    """Write Saved/Thumbnails/<role>.png from scene.json AABBs. Missing roles stay letter-only.
    force=True overwrites after SetOutline so ATX/card thumbs replace Mini-ITX captures.
    only_role recaptures that role after Add/Drop onto the live preview."""
    import json
    import os
    saved = os.path.join(unreal.Paths.project_saved_dir(), "Thumbnails")
    os.makedirs(saved, exist_ok=True)
    scene_path = os.path.join(unreal.Paths.project_content_dir(), "Boards", "scene.json")
    if not os.path.isfile(scene_path):
        unreal.log_warning("mbgen library thumbs skipped: no scene.json")
        return
    with open(scene_path, "r", encoding="utf-8") as handle:
        bodies = json.load(handle)
    world = _editor_world()
    wrote = 0
    miss = 0
    seen = set()
    cap = None
    comp = None
    rt = unreal.RenderingLibrary.create_render_target2d(
        world, 256, 256, unreal.TextureRenderTargetFormat.RTF_RGBA8, unreal.LinearColor(0.04, 0.04, 0.05, 1.0)
    )
    scale = 0.002
    for body in bodies:
        role = body.get("role")
        ident = body.get("id")
        if ident in ("pcb", "shield") or role in seen:
            continue
        if only_role and role != only_role:
            continue
        extent = max(abs(float(body.get("sx_um", 0))), abs(float(body.get("sy_um", 0))), abs(float(body.get("sz_um", 0))))
        if extent < 1000:
            continue
        seen.add(role)
        path = os.path.join(saved, f"{role}.png")
        if os.path.isfile(path) and not force and not only_role:
            wrote += 1
            continue
        cx = float(body["x_um"]) * scale
        cy = float(body["y_um"]) * scale
        cz = float(body["z_um"]) * scale
        span = max(float(body["sx_um"]), float(body["sy_um"]), float(body["sz_um"])) * scale
        span = max(span, 2.0)
        aim = unreal.Vector(cx, cy, cz)
        eye = unreal.Vector(cx + span * 1.4, cy - span * 2.2, cz + span * 1.6)
        rot = unreal.MathLibrary.find_look_at_rotation(eye, aim)
        if cap is None:
            cap = _spawn_actor(unreal.SceneCapture2D, eye, rot)
            comp = cap.capture_component2d
            comp.set_editor_property("texture_target", rt)
            comp.set_editor_property("capture_source", unreal.SceneCaptureSource.SCS_FINAL_COLOR_LDR)
            comp.set_editor_property("capture_every_frame", False)
            _set(comp, "always_persist_rendering_state", True)
        else:
            cap.set_actor_location(eye, False, False)
            cap.set_actor_rotation(rot, False)
        comp.set_editor_property("fov_angle", 32.0)
        comp.capture_scene()
        comp.capture_scene()
        unreal.RenderingLibrary.export_render_target(world, rt, saved + os.sep, f"{role}.png")
        wrote += 1
    if cap is not None:
        _destroy_actor(cap)
    lib_path = os.path.join(unreal.Paths.project_content_dir(), "Boards", "library.json")
    roles = []
    if os.path.isfile(lib_path):
        with open(lib_path, "r", encoding="utf-8") as handle:
            roles = [row.get("id") for row in json.load(handle)]
    for role in roles:
        if not os.path.isfile(os.path.join(saved, f"{role}.png")):
            miss += 1
    unreal.log(f"mbgen library thumbs wrote={wrote} miss={miss}")


def _world_has_map(token):
    world = _editor_world()
    if world is None:
        return False
    return token in world.get_path_name()


def _by_label(actors, label):
    found = []
    for actor in actors:
        try:
            if actor.get_actor_label() == label:
                found.append(actor)
        except Exception:
            pass
    return found


def _tune_light(actor, intensity, rotation, sun, shadows):
    light = actor.light_component
    _set(light, "mobility", unreal.ComponentMobility.MOVABLE)
    _set(light, "intensity", intensity)
    _set(light, "atmosphere_sun_light", sun)
    _set(light, "cast_shadows", shadows)
    try:
        actor.set_actor_rotation(rotation, False)
    except Exception as exc:
        unreal.log_warning(f"mbgen light rotation kept: {exc}")


def _ensure_view_lights():
    actors = list(_level_actors())
    dirs = [actor for actor in actors if actor.get_class().get_name() == "DirectionalLight"]
    key = _by_label(actors, "mbgen_key")
    fill = _by_label(actors, "mbgen_fill")
    if not key:
        key_actor = dirs[0] if dirs else _spawn_actor(
            unreal.DirectionalLight, unreal.Vector(0.0, 0.0, 0.0), unreal.Rotator(-52.0, 36.0, 0.0)
        )
        key_actor.set_actor_label("mbgen_key")
        key = [key_actor]
    if not fill:
        fill_actor = _spawn_actor(
            unreal.DirectionalLight, unreal.Vector(0.0, 0.0, 0.0), unreal.Rotator(-24.0, -148.0, 0.0)
        )
        fill_actor.set_actor_label("mbgen_fill")
        fill = [fill_actor]
    if "SkyAtmosphere" not in {actor.get_class().get_name() for actor in actors}:
        _spawn_actor(unreal.SkyAtmosphere, unreal.Vector(0.0, 0.0, 0.0))
    sky = [actor for actor in actors if actor.get_class().get_name() == "SkyLight"]
    if not sky:
        sky.append(_spawn_actor(unreal.SkyLight, unreal.Vector(0.0, 0.0, 0.0)))
    for actor in key:
        _tune_light(actor, 36.0, unreal.Rotator(-52.0, 36.0, 0.0), True, True)
    for actor in fill:
        _tune_light(actor, 10.0, unreal.Rotator(-24.0, -148.0, 0.0), False, False)
    for actor in sky:
        light = actor.light_component
        _set(light, "intensity", 0.55)
        _set(light, "real_time_capture", True)
        _set(light, "source_type", unreal.SkyLightSourceType.SLS_CAPTURED_SCENE)
        try:
            light.recapture_sky()
        except Exception as exc:
            unreal.log_warning(f"mbgen sky recapture kept: {exc}")
    unreal.log("mbgen lights key=36 fill=10 sky=0.55")


def _scene_index():
    import json
    import os
    path = os.path.join(unreal.Paths.project_content_dir(), "Boards", "scene.json")
    by_id = {}
    by_role = {}
    if not os.path.isfile(path):
        return by_id, by_role
    with open(path, "r", encoding="utf-8") as handle:
        rows = json.load(handle)
    if not isinstance(rows, list):
        return by_id, by_role
    scale = 0.002
    for body in rows:
        ident = body.get("id")
        if not ident:
            continue
        extent = max(
            abs(float(body.get("sx_um", 0))),
            abs(float(body.get("sy_um", 0))),
            abs(float(body.get("sz_um", 0))),
        )
        if ident != "pcb" and extent < 1000:
            continue
        vec = unreal.Vector(
            float(body["x_um"]) * scale,
            float(body["y_um"]) * scale,
            float(body["z_um"]) * scale,
        )
        by_id[ident] = vec
        role = body.get("role")
        if role and role not in by_role:
            by_role[role] = vec
    return by_id, by_role


def _scene_bodies():
    by_id, _ = _scene_index()
    return by_id


def _vadd(origin, dx, dy, dz):
    return unreal.Vector(origin.x + dx, origin.y + dy, origin.z + dz)


def _pcb_world():
    pcb = _scene_bodies().get("pcb")
    return pcb if pcb is not None else unreal.Vector(0.0, 0.0, 0.0)


def _aim_camera(board=None):
    if board is not None:
        try:
            board.call_method("FrameOrbit")
            return
        except Exception as exc:
            unreal.log_warning(f"mbgen FrameOrbit skipped: {exc}")
    aim = _pcb_world()
    eye = _vadd(aim, -410.0, -650.0, 352.0)
    rot = unreal.MathLibrary.find_look_at_rotation(eye, aim)
    unreal.get_editor_subsystem(unreal.UnrealEditorSubsystem).set_level_viewport_camera_info(eye, rot)


def diagnose_nav(board=None):
    """Read the live editor viewport camera, dump mbgen-navdiag.json, capture that render."""
    if board is None:
        for actor in _level_actors():
            if actor.get_class().get_name() == "MbgenBoardActor":
                board = actor
                break
    if board is not None:
        try:
            board.call_method("DiagnoseNav")
        except Exception as exc:
            unreal.log_warning(f"mbgen navdiag skipped: {exc}")
    world = _editor_world()
    try:
        loc, rot = unreal.get_editor_subsystem(unreal.UnrealEditorSubsystem).get_level_viewport_camera_info()
    except Exception as exc:
        unreal.log_warning(f"mbgen navdiag camera kept: {exc}")
        return
    rt = unreal.RenderingLibrary.create_render_target2d(
        world, 1280, 720, unreal.TextureRenderTargetFormat.RTF_RGBA8, unreal.LinearColor(0.02, 0.02, 0.025, 1.0)
    )
    cap = _spawn_actor(unreal.SceneCapture2D, loc, rot)
    comp = cap.capture_component2d
    comp.set_editor_property("texture_target", rt)
    comp.set_editor_property("capture_source", unreal.SceneCaptureSource.SCS_FINAL_COLOR_LDR)
    comp.set_editor_property("capture_every_frame", False)
    fov = 90.0
    try:
        import json
        import os
        path = os.path.join(unreal.Paths.project_saved_dir(), "mbgen-navdiag.json")
        if os.path.isfile(path):
            with open(path, "r", encoding="utf-8") as handle:
                meta = json.load(handle)
            fov = float(meta.get("fov") or 90.0)
    except Exception:
        pass
    comp.set_editor_property("fov_angle", fov)
    _set(comp, "always_persist_rendering_state", True)
    comp.capture_scene()
    comp.capture_scene()
    unreal.RenderingLibrary.export_render_target(world, rt, unreal.Paths.project_saved_dir(), "mbgen-navdiag.png")
    _destroy_actor(cap)
    unreal.log("mbgen navdiag capture wrote")


def _schedule_shot(board):
    # Scene capture only. FrameViewport's high-res shot repeats the last play
    # command and the capture then fails because the editor is in PIE.
    world = _editor_world()
    unreal.SystemLibrary.execute_console_command(world, "r.DefaultFeature.AutoExposure 1")
    unreal.SystemLibrary.execute_console_command(world, "r.EyeAdaptation.SpeedUp 8")
    unreal.SystemLibrary.execute_console_command(world, "r.EyeAdaptation.SpeedDown 8")
    unreal.SystemLibrary.execute_console_command(world, "r.BloomQuality 0")
    state = {"left": 90}

    def _tick(_delta):
        state["left"] -= 1
        if state["left"] == 20:
            try:
                _ensure_view_lights()
            except Exception as exc:
                unreal.log_warning(f"mbgen view lights skipped: {exc}")
        if state["left"] > 0:
            return
        try:
            level = unreal.get_editor_subsystem(unreal.LevelEditorSubsystem)
            if level.is_in_play_in_editor():
                level.editor_request_end_play()
                state["left"] = 15
                return
        except Exception as exc:
            unreal.log_warning(f"mbgen end play kept: {exc}")
        try:
            _capture_board()
        except Exception as exc:
            unreal.log_warning(f"mbgen board capture failed: {exc}")
        unreal.log("mbgen viewport shot requested")
        unreal.unregister_slate_post_tick_callback(state["handle"])

    state["handle"] = unreal.register_slate_post_tick_callback(_tick)


def place_board():
    """Show the packed board in the editor viewport, not only after Play."""
    map_path = "/Game/Maps/MbgenPreview"
    if not _world_has_map("MbgenPreview"):
        if not unreal.EditorAssetLibrary.does_asset_exist(map_path):
            _new_level(map_path)
        else:
            _load_map(map_path)
    board = None
    for actor in _level_actors():
        if actor.get_class().get_name() == "MbgenBoardActor":
            board = actor
            break
    if board is None:
        cls = unreal.load_class(None, "/Script/MbgenSim.MbgenBoardActor")
        board = _spawn_actor(cls, unreal.Vector(0.0, 0.0, 0.0))
    if board is None:
        unreal.log_error("mbgen board actor was not spawned")
        return
    board.call_method("RebuildFromDesign")
    board.call_method("CompileBoard")
    _label_materials()
    import json
    import os
    content = unreal.Paths.convert_relative_path_to_full(unreal.Paths.project_content_dir())
    product = content + "Boards/product/scene.json"
    product_n = 0
    if os.path.isfile(product):
        with open(product, "r", encoding="utf-8") as handle:
            bodies = json.load(handle)
        product_n = len(bodies) if isinstance(bodies, list) else 0
    unreal.log(f"mbgen product sections={product_n}")
    sections = board.get_components_by_class(unreal.ProceduralMeshComponent)
    if len(sections) == 0:
        unreal.log_error("mbgen board rebuilt with no sections")
        return
    try:
        _ensure_view_lights()
    except Exception as exc:
        unreal.log_warning(f"mbgen view lights skipped: {exc}")
    try:
        _aim_camera(board)
    except Exception as exc:
        unreal.log_warning(f"mbgen camera skipped: {exc}")
    _save_level()
    board.call_method("ProbeVisibility")
    try:
        diagnose_nav(board)
    except Exception as exc:
        unreal.log_warning(f"mbgen navdiag failed: {exc}")
    try:
        _schedule_shot(board)
    except Exception as exc:
        unreal.log_warning(f"mbgen viewport shot skipped: {exc}")
    unreal.log(f"mbgen board placed sections={len(sections)}")


def _import_one(tools, folder, png):
    task = unreal.AssetImportTask()
    task.set_editor_property("filename", folder + png + ".png")
    task.set_editor_property("destination_path", "/Game/Textures")
    task.set_editor_property("destination_name", png)
    task.set_editor_property("replace_existing", True)
    task.set_editor_property("automated", True)
    task.set_editor_property("save", True)
    tools.import_asset_tasks([task])


def _tune_texture(name, kind):
    tex = unreal.EditorAssetLibrary.load_asset(f"/Game/Textures/{name}")
    if not tex:
        unreal.log_warning(f"mbgen texture missing {name}")
        return
    if kind == "color":
        _set(tex, "srgb", True)
        _set(tex, "compression_settings", unreal.TextureCompressionSettings.TC_DEFAULT)
    elif kind == "linear":
        _set(tex, "srgb", False)
        _set(tex, "compression_settings", unreal.TextureCompressionSettings.TC_MASKS)
    else:
        _set(tex, "srgb", False)
        _set(tex, "compression_settings", unreal.TextureCompressionSettings.TC_NORMALMAP)
    unreal.EditorAssetLibrary.save_loaded_asset(tex)


def reimport_solder_maps():
    """Reload T_Solder* after mbgen textures writes new PNGs for the live outline.
    Delete first so a 512x410 ATX map replaces a 512x512 Mini-ITX asset."""
    try:
        unreal.SystemLibrary.collect_garbage()
    except Exception:
        try:
            unreal.KismetSystemLibrary.collect_garbage()
        except Exception:
            pass
    tools = unreal.AssetToolsHelpers.get_asset_tools()
    folder = unreal.Paths.convert_relative_path_to_full(unreal.Paths.project_content_dir()) + "Textures/"
    for name, kind in (
        ("T_SolderMask", "color"),
        ("T_SolderData", "linear"),
        ("T_SolderNormal", "normal"),
    ):
        path = f"/Game/Textures/{name}"
        if unreal.EditorAssetLibrary.does_asset_exist(path):
            unreal.EditorAssetLibrary.delete_asset(path)
        _import_one(tools, folder, name)
        _tune_texture(name, kind)
        tex = unreal.EditorAssetLibrary.load_asset(path)
        w = h = 0
        if tex:
            for xs, ys in (("blueprint_get_size_x", "blueprint_get_size_y"), ("get_size_x", "get_size_y")):
                if hasattr(tex, xs) and hasattr(tex, ys):
                    try:
                        w = int(getattr(tex, xs)())
                        h = int(getattr(tex, ys)())
                        break
                    except Exception:
                        continue
        unreal.log(f"mbgen textures reimport {name} {w}x{h}")
    mat = unreal.EditorAssetLibrary.load_asset("/Game/Materials/MSlot_solder_mask")
    if mat:
        unreal.MaterialEditingLibrary.recompile_material(mat)


def _import_textures():
    """The PNGs sit in Content/Textures but are not uassets until imported."""
    tools = unreal.AssetToolsHelpers.get_asset_tools()
    folder = unreal.Paths.convert_relative_path_to_full(unreal.Paths.project_content_dir()) + "Textures/"
    for png in COLOR_MAPS:
        _import_one(tools, folder, png)
        _tune_texture(png, "color")
    for png in DATA_MAPS:
        _import_one(tools, folder, png)
        _tune_texture(png, "linear")
    for png in NORMAL_MAPS:
        _import_one(tools, folder, png)
        _tune_texture(png, "normal")
    for png in ("T_SolderMask", "T_Gold", "T_Metal", "T_SolderData", "T_SolderNormal"):
        tex = unreal.EditorAssetLibrary.load_asset(f"/Game/Textures/{png}")
        unreal.log(f"mbgen import {png} {'ok' if tex else 'missing'}")


def build():
    _import_textures()
    for name, spec in SLOTS.items():
        _lit_slot(name, spec)
    unreal.log("mbgen PBR materials ready")
    place_board()


build()
