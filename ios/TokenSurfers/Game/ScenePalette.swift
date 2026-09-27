import SwiftUI
import UIKit

/// The backdrop's colours per scene (SurfEngine.sceneNames). A scene change is
/// a palette swap on draws that already happen, cross-faded by lerping the
/// colours — no extra fills, except the two skyline strips (drawn twice only
/// during the ~3 s fade) and a few cheap extras (stars, the moon's bite, the
/// vaporwave sun's stripes) that only draw when their amount is above zero.
struct ScenePalette {
    struct RGB {
        var r, g, b: Double
        init(_ hex: UInt32) { r = Double((hex >> 16) & 0xFF) / 255; g = Double((hex >> 8) & 0xFF) / 255; b = Double(hex & 0xFF) / 255 }
        init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
        func mix(_ o: RGB, _ t: Double) -> RGB { RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t) }
        var color: Color { Color(red: r, green: g, blue: b) }
        var ui: UIColor { UIColor(red: r, green: g, blue: b, alpha: 1) }
    }

    /// Raw scene definition (hex values), blended then resolved to Colors.
    struct Def {
        var sky: [UInt32]            // top, middle, horizon
        var sun: UInt32, halo: UInt32
        var haze: [UInt32]           // band at the horizon
        var skyline: [UInt32]        // far, near
        var windows: UInt32
        var ground: [UInt32]
        var ballast: UInt32
        var platTop: UInt32, platFace: UInt32, safety: UInt32
        var wall: UInt32, trim: UInt32
        var sleeper: UInt32, rail: UInt32
        var posters: [UInt32]        // 6
        var words: [String]          // 8
        var stars: Double            // 0…1
        var bite: Double             // 0…1: a crescent moon
        var stripes: Double          // 0…1: the vaporwave sun
    }

    static let defs: [Def] = [
        // golden hour: the original look
        Def(sky: [0xEE7F52, 0xF6B47C, 0xFAD8A0], sun: 0xFCEBB8, halo: 0xFCE7B0, haze: [0xF9D39A, 0xF3C3A0],
            skyline: [0xC46A8B, 0x9B3F6E], windows: 0xFFE3A6, ground: [0x9C8FAE, 0x6E6388, 0x584D70], ballast: 0x3F3552,
            platTop: 0xB7ACC6, platFace: 0x8C819F, safety: 0xF2C94C, wall: 0x7C7299, trim: 0x9A90B8,
            sleeper: 0x4B3440, rail: 0xE4DDF7,
            posters: [0xF2C14E, 0xE25C4B, 0x8C6BE0, 0x3FB5A5, 0xF08BB0, 0x4F8FD6],
            words: ["TOKEN SURFERS", "made with code", "LGTM", "SHIP IT", "brb 3am", "no comments", "x_final_final", "let him cook"],
            stars: 0, bite: 0, stripes: 0),
        // night shift: navy, a crescent, stars, neon posters
        Def(sky: [0x0B1030, 0x1B2150, 0x3A3470], sun: 0xEDEBFF, halo: 0x9AA4FF, haze: [0x3A3470, 0x5A4C7A],
            skyline: [0x2A2E5E, 0x1A1C40], windows: 0xFFD86B, ground: [0x4A4368, 0x332D4E, 0x241F3A], ballast: 0x120E20,
            platTop: 0x5B5480, platFace: 0x3E3862, safety: 0xF2C94C, wall: 0x2E2A50, trim: 0x45407A,
            sleeper: 0x1E1628, rail: 0xB9B4E8,
            posters: [0xFF4FA3, 0x3DE0FF, 0xB6F23A, 0xFFC31F, 0x9B6BFF, 0xFF6B3D],
            words: ["TOKEN SURFERS", "still up?", "ship at dawn", "LGTM", "3:00 AM", "one more prompt", "no sleep", "deploy friday"],
            stars: 1, bite: 1, stripes: 0),
        // vaporwave: magenta dusk, a striped sun, cyan rails
        Def(sky: [0x2B1055, 0x7A2A8C, 0xFF6FB5], sun: 0xFFD36E, halo: 0xFF9ED8, haze: [0xFF8CC6, 0xE86BB0],
            skyline: [0x5B1E7A, 0x3A0E5E], windows: 0x7DF9FF, ground: [0x3B2A7A, 0x2A1D5E, 0x1A1240], ballast: 0x0E0A2A,
            platTop: 0x6E5AC8, platFace: 0x4A3A9A, safety: 0x7DF9FF, wall: 0x4B2F8F, trim: 0x7A5CD0,
            sleeper: 0x1A1240, rail: 0xFF8CE0,
            posters: [0xFF6FB5, 0x7DF9FF, 0xFFD36E, 0xB98CFF, 0x5BFFB0, 0xFF9E5E],
            words: ["TOKEN SURFERS", "A E S T H E T I C", "vibe coded", "LGTM", "wave.exe", "1995 forever", "palm.png", "ship it"],
            stars: 0.45, bite: 0, stripes: 1),
        // server room: terminal green on black
        Def(sky: [0x04140C, 0x0A2A1A, 0x12402A], sun: 0x3DFF8A, halo: 0x2FE08A, haze: [0x12402A, 0x1C5A3A],
            skyline: [0x0F3322, 0x082214], windows: 0x2FE08A, ground: [0x22332C, 0x16241E, 0x0C1612], ballast: 0x050A08,
            platTop: 0x33483F, platFace: 0x22332C, safety: 0x2FE08A, wall: 0x1A2A23, trim: 0x2F4A3E,
            sleeper: 0x0A120E, rail: 0x8CFFC0,
            posters: [0x2FE08A, 0x1C8C5A, 0x3DFFB0, 0x0FAF6A, 0x8CFFC0, 0x2FE08A],
            words: ["sudo ship", "200 OK", "rm -rf bugs", "git push", "LGTM", "npm i vibes", "segfault", "TOKEN SURFERS"],
            stars: 0.3, bite: 0, stripes: 0),
    ]

    // resolved
    let sky: [Color], sun: Color, halo: Color, haze: [Color], skyBase: Color
    let ground: [Color], ballast: Color
    let platTop: Color, platFace: Color, safety: Color, wall: Color, trim: Color
    let sleeper: Color, rail: Color, posters: [Color]
    let words: [String]
    let stars: Double, bite: Double, stripes: Double

    /// The palette for this frame: a cached one outside a fade, else a blend.
    static func current(_ e: SurfEngine) -> ScenePalette {
        let t = e.sceneBlend
        if t >= 1 { return resolved[e.sceneNow] }
        return ScenePalette(defs[e.scenePrev], defs[e.sceneNow], t)
    }

    private static let resolved: [ScenePalette] = defs.map { ScenePalette($0, $0, 1) }

    private init(_ a: Def, _ b: Def, _ t: Double) {
        func c(_ x: UInt32, _ y: UInt32) -> Color { RGB(x).mix(RGB(y), t).color }
        func cs(_ x: [UInt32], _ y: [UInt32]) -> [Color] { zip(x, y).map { c($0, $1) } }
        func n(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        sky = cs(a.sky, b.sky); sun = c(a.sun, b.sun); halo = c(a.halo, b.halo); haze = cs(a.haze, b.haze)
        skyBase = c(a.sky[1], b.sky[1])
        ground = cs(a.ground, b.ground); ballast = c(a.ballast, b.ballast)
        platTop = c(a.platTop, b.platTop); platFace = c(a.platFace, b.platFace); safety = c(a.safety, b.safety)
        wall = c(a.wall, b.wall); trim = c(a.trim, b.trim)
        sleeper = c(a.sleeper, b.sleeper); rail = c(a.rail, b.rail)
        posters = cs(a.posters, b.posters)
        words = t < 0.5 ? a.words : b.words
        stars = n(a.stars, b.stars); bite = n(a.bite, b.bite); stripes = n(a.stripes, b.stripes)
    }
}

/// A sky full of stars, rendered once per size.
enum StarCache {
    nonisolated(unsafe) private static var images: [String: UIImage] = [:]

    static func image(width: Double, height: Double, alpha: Double = 1) -> UIImage {
        let a = min(10, max(1, Int((alpha * 10).rounded())))
        let key = "\(Int(width))x\(Int(height))@\(a)"
        if let hit = images[key] { return hit }
        let alpha = Double(a) / 10
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        let img = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { rc in
            let c = rc.cgContext
            var rng = SeededRandom(seed: 7)
            for _ in 0..<Int(width * height / 900) {
                let r = 0.5 + rng.unit() * 1.1
                c.setFillColor(UIColor.white.withAlphaComponent((0.35 + rng.unit() * 0.6) * alpha).cgColor)
                c.fillEllipse(in: CGRect(x: rng.unit() * width, y: rng.unit() * height, width: r * 2, height: r * 2))
            }
        }
        images[key] = img
        return img
    }
}
