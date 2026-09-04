#!/usr/bin/env swift
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("generate-eac-main: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail("usage: generate-eac-main.swift INPUT OUTPUT")
}

let input = CommandLine.arguments[1]
let output = CommandLine.arguments[2]
var source: String
do {
    source = try String(contentsOfFile: input, encoding: .utf8)
} catch {
    fail("cannot read \(input): \(error)")
}

func replaceOnce(_ needle: String, with replacement: String) {
    guard let range = source.range(of: needle) else {
        fail("expected source fragment not found: \(needle.prefix(80))")
    }
    source.replaceSubrange(range, with: replacement)
}

// Experimental YouTube EAC support lives in a generated source file for now,
// so the feature can be tested without making a large mechanical replacement
// of main.swift on the branch. Once validated, this should be folded directly
// into main.swift.
let projectSignature = "static float2 project_dir(float3 w, int mode, int stereo, int eye, float fovRad, float shift, thread bool &valid) {"
let eacHelper = #"""
// YouTube/FFmpeg Equi-Angular Cubemap (EAC), 3x2 layout.
// Face packing matches FFmpeg v360 prepare_eac_in():
//   top:    LEFT | FRONT | RIGHT
//   bottom: DOWN | BACK  | UP
// Bottom faces use the same rotations as FFmpeg (270, 90, 270 degrees).
// GAV uses x-right/y-up/-z-forward; FFmpeg's cubemap convention is
// x-right/y-down/+z-forward, hence the axis conversion below.
static float2 project_eac(float3 w) {
    float3 p = float3(w.x, -w.y, -w.z);
    float ax = fabs(p.x), ay = fabs(p.y), az = fabs(p.z);

    float uf = 0.0, vf = 0.0;
    int col = 1, row = 0;
    int rotation = 0; // 0, 1=90, 3=270

    if (ax >= ay && ax >= az) {
        if (p.x >= 0.0) {
            uf = -p.z / p.x;
            vf =  p.y / p.x;
            col = 2; row = 0;
        } else {
            uf = -p.z / p.x;
            vf = -p.y / p.x;
            col = 0; row = 0;
        }
    } else if (ay >= ax && ay >= az) {
        if (p.y >= 0.0) {
            uf =  p.x / p.y;
            vf = -p.z / p.y;
            col = 0; row = 1; rotation = 3;
        } else {
            uf = -p.x / p.y;
            vf = -p.z / p.y;
            col = 2; row = 1; rotation = 3;
        }
    } else {
        if (p.z >= 0.0) {
            uf = p.x / p.z;
            vf = p.y / p.z;
            col = 1; row = 0;
        } else {
            uf = p.x / p.z;
            vf = -p.y / p.z;
            col = 1; row = 1; rotation = 1;
        }
    }

    if (rotation == 1) {
        float t = uf; uf = -vf; vf = t;
    } else if (rotation == 3) {
        float t = -uf; uf = vf; vf = t;
    }

    uf = (2.0 / PI) * atan(uf) + 0.5;
    vf = (2.0 / PI) * atan(vf) + 0.5;
    return float2((uf + float(col)) / 3.0,
                  (vf + float(row)) / 2.0);
}

"""#
replaceOnce(projectSignature, with: eacHelper + projectSignature)

replaceOnce("    if (mode == 2) {\n        // equidistant fisheye, forward axis -Z",
            with: "    if (mode == 3) {\n        float2 eac = project_eac(w);\n        u = eac.x;\n        v = eac.y;\n    } else if (mode == 2) {\n        // equidistant fisheye, forward axis -Z")

replaceOnce("    case fisheye = 2\n", with: "    case fisheye = 2\n    case eac360 = 3\n")

let labelBlock = #"""
    var label: String {
        switch self {
        case .equirect360: return "equirect 360°"
        case .equirect180: return "half-equirect 180°"
        case .fisheye: return "fisheye"
        }
    }
"""#
let labelBlockEAC = #"""
    var label: String {
        switch self {
        case .equirect360: return "equirect 360°"
        case .equirect180: return "half-equirect 180°"
        case .fisheye: return "fisheye"
        case .eac360: return "YouTube EAC 360°"
        }
    }
"""#
replaceOnce(labelBlock, with: labelBlockEAC)

let shortLabelBlock = #"""
    var shortLabel: String {
        switch self {
        case .equirect360: return "360°"
        case .equirect180: return "180°"
        case .fisheye: return "fisheye"
        }
    }
"""#
let shortLabelBlockEAC = #"""
    var shortLabel: String {
        switch self {
        case .equirect360: return "360°"
        case .equirect180: return "180°"
        case .fisheye: return "fisheye"
        case .eac360: return "EAC 360°"
        }
    }
"""#
replaceOnce(shortLabelBlock, with: shortLabelBlockEAC)

let detectStart = #"""
        if n.contains("FISHEYE") || n.contains("VR180FISH") {
            cfg.projection = .fisheye
"""#
let detectStartEAC = #"""
        // YouTube downloads produced by player/play include [YT] and the
        // selected frame dimensions as [WIDTHxHEIGHT]. Use a ~3:2 aspect ratio
        // only for these tagged files as the EAC signal; arbitrary local 3:2
        // videos remain untouched.
        var cachedAspect: Float? = nil
        if let r = n.range(of: #"\[(\d{3,5})X(\d{3,5})\]"#, options: .regularExpression) {
            let dims = String(n[r]).dropFirst().dropLast().split(separator: "X")
            if dims.count == 2, let w = Float(dims[0]), let h = Float(dims[1]), h > 0 {
                cachedAspect = w / h
            }
        }
        let looksLikeEAC = n.contains("[YT]") && cachedAspect.map { $0 > 1.40 && $0 < 1.65 } == true

        if n.contains("EAC360") || n.contains("_EAC") || looksLikeEAC {
            cfg.projection = .eac360
        } else if n.contains("FISHEYE") || n.contains("VR180FISH") {
            cfg.projection = .fisheye
"""#
replaceOnce(detectStart, with: detectStartEAC)
replaceOnce("        } else if cfg.projection == .equirect360 {\n            cfg.stereo = .mono\n",
            with: "        } else if cfg.projection == .equirect360 || cfg.projection == .eac360 {\n            cfg.stereo = .mono\n")

do {
    try source.write(toFile: output, atomically: true, encoding: .utf8)
} catch {
    fail("cannot write \(output): \(error)")
}
