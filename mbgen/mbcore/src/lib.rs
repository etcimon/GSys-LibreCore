//! Shared arithmetic for the motherboard preview and the compiler.
//!
//! Lengths are micrometres. A gesture either returns a new legal design or
//! the previous design unchanged, with a reason. Unreal paints the result
//! and does not keep a pose this library rejected.

mod catalog;
mod export;
mod gesture;
mod library;
mod nav;
mod net;
mod pack;
mod profile;
mod route;
mod scene;
mod template;

pub use catalog::{
    apply_package, domain_for, library_for, package, packages, LibraryRow, PackageCard, Support,
};
pub use export::{compile, Bundle};
pub use gesture::{preview, Gesture, PreviewResult, SNAP_UM};
pub use library::{library_export, LibraryEntry};
pub use nav::{
    clamp_sens, clamp_wheel, desk_from_board, hit_desk, look_in_place, look_in_place_pose,
    orbit_around, pick_nav_pivot, zoom_distance, zoom_toward,
    Desk, Vec3 as NavVec3, DEFAULT_SENS, DESK_PAD, MAX_DIST, MIN_DIST, ORBIT_PITCH_PER_PX,
    ORBIT_YAW_PER_PX, WHEEL_NOTCH_LIMIT, ZOOM_RATIO,
};
pub use net::{
    anchors, auto_connect, contracts_for, pin_spec, pins_for, Anchor, AnchorKind, Hit, Net,
    NetClass, NetError, NetErrorKind, Path, PathHitKind, Pin, PinKind, PinSide, PinSpec,
};
pub use pack::{pack_edge, split_span, Interval, PackError, SpanPart};
pub use profile::{
    generate_from_dir, profile, profile_from_facts, profiles, profiles_json, read_config_pkg,
    read_config_pkg_with, sha256_hex, shared_constants, target_id_from_filename, ConfigFacts, CoreProfile,
    ProfileSource, SvValue, PROFILES_SCHEMA_VERSION,
};
pub use route::{
    astar, corridor_x_um, route, Occupancy, RouteResult, BODY_KEEP_UM, GRID_UM, TRACE_CLEAR_UM,
    TRACE_HALF_UM, VIA_CLEAR_UM,
};
pub use scene::{scene, um_from_local_cm, Body, PCB_TOP_CM};
pub use template::{
    atx, card_sit, matx, mini_itx, motherboard_sit, outline_ids, pcie_card, pico_itx, pico_sit, role,
    role_extents, roles, template_by_id, Design, Edge, Placement, Port, Role, Settings, Sit, Template,
    DESIGN_SCHEMA_VERSION,
};

/// Courtyard gap between packed bodies, in micrometres.
pub const DEFAULT_GAP_UM: i64 = 1_500;
