//! One unit cube, instanced per body. glTF is Y-up; the scene is Z-up.

use std::fs;
use std::path::Path;

use mbcore::Body;
use serde_json::json;

pub fn write_board(path: &Path, bodies: &[Body]) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let (positions, normals, uvs, indices) = unit_cube();
    let mut bin = Vec::new();
    push_f32(&mut bin, &positions);
    let n0 = bin.len();
    push_f32(&mut bin, &normals);
    let u0 = bin.len();
    push_f32(&mut bin, &uvs);
    let i0 = bin.len();
    for i in &indices {
        bin.extend_from_slice(&i.to_le_bytes());
    }
    let bin_name = "cube.bin";
    fs::write(path.with_file_name(bin_name), &bin).map_err(|e| e.to_string())?;

    let materials = ["solder_mask", "metal", "plastic", "gold", "ceramic", "ghost"];
    let mat_json: Vec<_> = materials
        .iter()
        .map(|name| {
            let (metal, rough, color) = pbr(name);
            json!({
                "name": name,
                "pbrMetallicRoughness": {
                    "baseColorFactor": color,
                    "metallicFactor": metal,
                    "roughnessFactor": rough
                },
                "emissiveFactor": if *name == "ghost" { [0.45, 0.12, 0.02] } else { [0.0, 0.0, 0.0] }
            })
        })
        .collect();

    let mut nodes = Vec::new();
    for body in bodies {
        let (sx, sy, sz) = metres(body.sx_um, body.sy_um, body.sz_um);
        let (tx, ty, tz) = metres(body.x_um, body.z_um, body.y_um);
        let mat = materials.iter().position(|m| *m == body.material).unwrap_or(0);
        nodes.push(json!({
            "name": body.id,
            "mesh": 0,
            "translation": [tx, ty, tz],
            "scale": [sx, sy, sz],
            "extras": { "material": mat, "role": body.role, "support": body.support }
        }));
    }
    // Primitive uses material 0. Per-node material is in extras; a second
    // mesh per material keeps the file valid for importers that ignore extras.
    let doc = json!({
        "asset": { "version": "2.0", "generator": "mbgen" },
        "scene": 0,
        "scenes": [{ "nodes": (0..nodes.len()).collect::<Vec<_>>() }],
        "nodes": nodes,
        "materials": mat_json,
        "meshes": [{
            "primitives": [{
                "attributes": { "POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2 },
                "indices": 3,
                "material": 0
            }]
        }],
        "buffers": [{ "uri": bin_name, "byteLength": bin.len() }],
        "bufferViews": [
            { "buffer": 0, "byteOffset": 0, "byteLength": n0, "target": 34962 },
            { "buffer": 0, "byteOffset": n0, "byteLength": u0 - n0, "target": 34962 },
            { "buffer": 0, "byteOffset": u0, "byteLength": i0 - u0, "target": 34962 },
            { "buffer": 0, "byteOffset": i0, "byteLength": bin.len() - i0, "target": 34963 }
        ],
        "accessors": [
            accessor(0, positions.len() / 3, "VEC3", 5126, [-0.5, -0.5, -0.5], [0.5, 0.5, 0.5]),
            accessor(1, normals.len() / 3, "VEC3", 5126, [-1.0, -1.0, -1.0], [1.0, 1.0, 1.0]),
            accessor(2, uvs.len() / 2, "VEC2", 5126, [0.0, 0.0, 0.0], [1.0, 1.0, 0.0]),
            { "bufferView": 3, "componentType": 5123, "count": indices.len(), "type": "SCALAR" }
        ]
    });
    fs::write(path, serde_json::to_string_pretty(&doc).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())
}

fn accessor(view: i32, count: usize, ty: &str, component: i32, min: [f32; 3], max: [f32; 3]) -> serde_json::Value {
    if ty == "VEC2" {
        json!({ "bufferView": view, "componentType": component, "count": count, "type": ty, "min": [min[0], min[1]], "max": [max[0], max[1]] })
    } else {
        json!({ "bufferView": view, "componentType": component, "count": count, "type": ty, "min": min, "max": max })
    }
}

fn pbr(name: &str) -> (f32, f32, [f32; 4]) {
    match name {
        "metal" => (1.0, 0.32, [0.72, 0.73, 0.75, 1.0]),
        "plastic" => (0.0, 0.48, [0.12, 0.12, 0.13, 1.0]),
        "gold" => (1.0, 0.28, [0.83, 0.66, 0.22, 1.0]),
        "ceramic" => (0.0, 0.62, [0.74, 0.71, 0.62, 1.0]),
        "ghost" => (0.05, 0.8, [0.35, 0.12, 0.08, 1.0]),
        _ => (0.0, 0.55, [0.05, 0.32, 0.16, 1.0]),
    }
}

fn metres(x: i64, y: i64, z: i64) -> (f32, f32, f32) {
    ((x as f32) * 1.0e-6, (y as f32) * 1.0e-6, (z as f32) * 1.0e-6)
}

fn push_f32(bin: &mut Vec<u8>, values: &[f32]) {
    for v in values {
        bin.extend_from_slice(&v.to_le_bytes());
    }
}

fn unit_cube() -> (Vec<f32>, Vec<f32>, Vec<f32>, Vec<u16>) {
    let faces: [[f32; 3]; 6] = [
        [0.0, 0.0, 1.0],
        [0.0, 0.0, -1.0],
        [0.0, 1.0, 0.0],
        [0.0, -1.0, 0.0],
        [1.0, 0.0, 0.0],
        [-1.0, 0.0, 0.0],
    ];
    let mut pos = Vec::new();
    let mut nrm = Vec::new();
    let mut uv = Vec::new();
    let mut idx = Vec::new();
    for (f, n) in faces.iter().enumerate() {
        let base = (f * 4) as u16;
        let corners = face_corners(*n);
        for (p, t) in corners {
            pos.extend_from_slice(&p);
            nrm.extend_from_slice(n);
            uv.extend_from_slice(&t);
        }
        idx.extend_from_slice(&[base, base + 1, base + 2, base, base + 2, base + 3]);
    }
    (pos, nrm, uv, idx)
}

fn face_corners(n: [f32; 3]) -> [([f32; 3], [f32; 2]); 4] {
    let (u, v) = if n[2].abs() > 0.5 {
        ([1.0, 0.0, 0.0], [0.0, 1.0, 0.0])
    } else if n[1].abs() > 0.5 {
        ([1.0, 0.0, 0.0], [0.0, 0.0, 1.0])
    } else {
        ([0.0, 1.0, 0.0], [0.0, 0.0, 1.0])
    };
    let c = |su: f32, sv: f32, tu: f32, tv: f32| {
        (
            [
                n[0] * 0.5 + u[0] * su + v[0] * sv,
                n[1] * 0.5 + u[1] * su + v[1] * sv,
                n[2] * 0.5 + u[2] * su + v[2] * sv,
            ],
            [tu, tv],
        )
    };
    [c(-0.5, -0.5, 0.0, 0.0), c(0.5, -0.5, 1.0, 0.0), c(0.5, 0.5, 1.0, 1.0), c(-0.5, 0.5, 0.0, 1.0)]
}
