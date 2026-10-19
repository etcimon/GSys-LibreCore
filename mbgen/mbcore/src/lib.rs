//! Shared arithmetic for the motherboard preview and the compiler.
//!
//! Lengths are micrometres. A gesture either returns a new legal design or
//! the previous design unchanged, with a reason. Unreal paints the result
//! and does not keep a pose this library rejected.

mod catalog;
mod circuit;
mod export;
mod geometry;
mod gesture;
mod library;
mod nav;
mod net;
mod pack;
mod profile;
mod recipes;
mod route;
mod soc_package;
mod scene;
mod template;

pub use catalog::{
    apply_package, domain_for, library_for, package, packages, LibraryRow, PackageCard, Support,
};
pub use circuit::{resolve, Circuit, CircuitNet, Component, Diagnostic, Obligation, CIRCUIT_SCHEMA_VERSION};
pub use export::{compile, suggested_decaps, Bundle, BUNDLE_SCHEMA_VERSION};
pub use geometry::{
    body_z, copper_z, layer_of, pad_world, rotate_q, world_span, Rect, BOTTOM_COPPER_Z_UM, PCB_THICKNESS_UM,
    TOP_COPPER_Z_UM,
};
pub use gesture::{propose_outline, OutlineDrop, OutlineMove, OutlineProposal};
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
pub use recipes::{apply_proposal, disown, propose, remove_block, Proposal, ProposedPart, RECIPE_DECAP_PER_RAIL};
pub use soc_package::{assess as assess_soc_package, assess_text as assess_soc_package_text, SocPackageReport, SOC_PACKAGE_JSON};
pub use route::{
    corridor_x_um, hit_z_um, route, route_circuit, route_incremental, route_nets, terminal_of, terminals_for, Keep,
    Occupancy, RouteResult, Terminal, BODY_KEEP_UM, GRID_UM, RIP_UP_ROUNDS, SEARCH_BUDGET, TRACE_CLEAR_UM,
    TRACE_HALF_UM, VIA_CLEAR_UM,
};
pub use scene::{scene, um_from_local_cm, Body, PCB_TOP_CM};
pub use template::{
    atx, card_sit, matx, mini_itx, motherboard_sit, outline_ids, pcie_card, pico_itx, pico_sit, refdes_prefix,
    role, role_extents, roles, template_by_id, CircuitBlock, Connection, Design, Edge, PartRef, Placement, Port,
    Role, Settings, Side, Sit, Template, DESIGN_SCHEMA_VERSION,
};

/// Courtyard gap between packed bodies, in micrometres.
pub const DEFAULT_GAP_UM: i64 = 1_500;
