import RealityKit
import UIKit

/// Baut das AR-Modell des Spielzeug-Geländewagens.
///
/// Normalerweise ist das die gescannte Karosserie aus `ToyCar.usdz`. Fehlt die Datei, wird ein
/// Ersatzmodell aus Grundformen gebaut. In beiden Fällen setzt die App die beweglichen Teile
/// (Räder, Wischer, Lichter) selbst ein, an den Stellen aus dem passenden `Layout`.
///
/// Modellkoordinaten: Länge 1 entlang z (vorne = -z), Boden bei y = 0, rechts = +x.
/// `placedAtRealSize` skaliert das Modell anschließend auf die Größe des echten Autos.
@MainActor
enum CarModelFactory {
    static func makeCar() -> Entity {
        let palette = Palette()
        let car = Entity()
        car.name = "ToyCar"
        if Bundle.main.url(forResource: "ToyCar", withExtension: "usdz") != nil,
           let body = try? Entity.load(named: "ToyCar") {
            showTextureUnlit(body)
            car.addChild(body)
            addMovingParts(to: car, layout: .scanned, palette: palette)
        } else {
            addProceduralBody(to: car, palette: palette)
            addMovingParts(to: car, layout: .procedural, palette: palette)
        }
        return car
    }

    /// Gemessen am echten Auto: 10,2 cm vom Kanister hinten bis zur vorderen Stoßstange.
    /// Muss zur Länge passen, mit der das Trainingsmodell exportiert wurde (tools/scan_to_usdz/export_usdz.py).
    static let realLength: Float = 0.102

    /// Breite, Höhe und Länge des echten Autos in Metern (aus dem Scan, mit Rädern).
    static let realSize = SIMD3<Float>(0.052, 0.063, 0.102)

    /// Bringt das Auto auf echte Größe. Das Trainingsmodell für die Erkennung liegt im selben
    /// Koordinatensystem (nur mit `realLength` skaliert), und beim Einlernen am iPhone wird das
    /// Referenzobjekt genau an diesem Modell ausgerichtet. Deshalb sitzt das Modell ohne weitere
    /// Verschiebung auf dem erkannten Auto.
    static func placedAtRealSize(_ car: Entity) -> Entity {
        let container = Entity()
        container.addChild(car)
        container.scale = SIMD3(repeating: realLength)
        return container
    }

    /// Die Scan-Textur enthält das echte Licht schon. Zusätzlich von der (oft dunklen) Umgebung
    /// beleuchtet, wirkte die Karosserie viel zu dunkel – unbeleuchtet sieht sie aus wie auf den Fotos.
    private static func showTextureUnlit(_ entity: Entity) {
        if var model = entity.components[ModelComponent.self] {
            model.materials = model.materials.map { material in
                guard let lit = material as? PhysicallyBasedMaterial else { return material }
                var unlit = UnlitMaterial()
                unlit.color = .init(tint: .white, texture: lit.baseColor.texture)
                return unlit
            }
            entity.components.set(model)
        }
        entity.children.forEach(showTextureUnlit)
    }

    // MARK: - Lage der beweglichen Teile

    struct Layout {
        var wheelRadius: Float
        var wheelWidth: Float
        /// Abstand der Radmitten von der Mittelachse (x).
        var wheelOffsetX: Float
        var frontAxleZ: Float
        var rearAxleZ: Float
        /// Drehpunkte links, rechts; die Arme zeigen in Ruhe nach +x.
        var wiperPivots: [SIMD3<Float>]
        var wiperLength: Float
        /// Neigung der Windschutzscheibe nach hinten (Bogenmaß).
        var windshieldTilt: Float
        var headlights: [SIMD3<Float>]
        var headlightRadius: Float
        var frontIndicators: [SIMD3<Float>]
        var frontIndicatorSize: SIMD3<Float>
        var rearIndicators: [SIMD3<Float>]
        var rearIndicatorSize: SIMD3<Float>

        /// Vermessen am Scan `ToyCar.usdz` (siehe tools/scan_to_usdz).
        static let scanned = Layout(
            wheelRadius: 0.108,
            wheelWidth: 0.10,
            wheelOffsetX: 0.198,
            frontAxleZ: -0.31,
            rearAxleZ: 0.243,
            wiperPivots: [[-0.14, 0.36, -0.158], [0.01, 0.36, -0.158]],
            wiperLength: 0.13,
            windshieldTilt: 0.346,
            headlights: [[-0.165, 0.26, -0.447], [0.165, 0.26, -0.447]],
            headlightRadius: 0.03,
            frontIndicators: [[-0.15, 0.333, -0.40], [0.15, 0.333, -0.40]],
            frontIndicatorSize: [0.04, 0.01, 0.03],
            rearIndicators: [[-0.19, 0.16, 0.432], [0.19, 0.16, 0.432]],
            rearIndicatorSize: [0.035, 0.025, 0.01]
        )

        static let procedural = Layout(
            wheelRadius: 0.135,
            wheelWidth: 0.10,
            wheelOffsetX: 0.235,
            frontAxleZ: -0.31,
            rearAxleZ: 0.31,
            wiperPivots: [[-0.18, 0.425, -0.162], [0.02, 0.425, -0.162]],
            wiperLength: 0.16,
            windshieldTilt: 0,
            headlights: [[-0.17, 0.33, -0.445], [0.17, 0.33, -0.445]],
            headlightRadius: 0.035,
            frontIndicators: [[-0.17, 0.385, -0.444], [0.17, 0.385, -0.444]],
            frontIndicatorSize: [0.045, 0.025, 0.01],
            rearIndicators: [[-0.19, 0.27, 0.444], [0.19, 0.27, 0.444]],
            rearIndicatorSize: [0.045, 0.025, 0.01]
        )
    }

    // MARK: - Bauteile

    @MainActor
    private struct Palette {
        let sand = SimpleMaterial(color: UIColor(red: 0.80, green: 0.74, blue: 0.56, alpha: 1), roughness: 0.7, isMetallic: false)
        let black = SimpleMaterial(color: UIColor(white: 0.08, alpha: 1), roughness: 0.6, isMetallic: false)
        let tire = SimpleMaterial(color: UIColor(white: 0.05, alpha: 1), roughness: 0.9, isMetallic: false)
        let rim = SimpleMaterial(color: UIColor(white: 0.62, alpha: 1), roughness: 0.35, isMetallic: true)
        let glass = SimpleMaterial(color: UIColor(red: 0.08, green: 0.10, blue: 0.12, alpha: 1), roughness: 0.1, isMetallic: false)
        let red = SimpleMaterial(color: UIColor(red: 0.85, green: 0.22, blue: 0.18, alpha: 1), roughness: 0.6, isMetallic: false)
        let white = SimpleMaterial(color: UIColor(white: 0.93, alpha: 1), roughness: 0.9, isMetallic: false)
        let plate = SimpleMaterial(color: UIColor(red: 0.92, green: 0.80, blue: 0.35, alpha: 1), roughness: 0.5, isMetallic: false)
        let headlightOff = SimpleMaterial(color: UIColor(white: 0.85, alpha: 1), roughness: 0.15, isMetallic: true)
        let indicatorOff = SimpleMaterial(color: UIColor(red: 0.75, green: 0.42, blue: 0.10, alpha: 1), roughness: 0.3, isMetallic: false)
        let tailLight = SimpleMaterial(color: UIColor(red: 0.60, green: 0.05, blue: 0.05, alpha: 1), roughness: 0.3, isMetallic: false)
    }

    private enum Axis {
        case x, y, z

        /// Dreht einen Zylinder (Achse = y) auf diese Achse.
        var cylinderOrientation: simd_quatf {
            switch self {
            case .x: simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
            case .y: simd_quatf(angle: 0, axis: [0, 1, 0])
            case .z: simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
            }
        }
    }

    /// Räder, Wischer und Lichter mit den Namen, nach denen `CarAnimator` sucht.
    private static func addMovingParts(to car: Entity, layout l: Layout, palette p: Palette) {
        let wheelY = l.wheelRadius
        let wheels: [(String, SIMD3<Float>)] = [
            ("wheel_FL", [-l.wheelOffsetX, wheelY, l.frontAxleZ]),
            ("wheel_FR", [l.wheelOffsetX, wheelY, l.frontAxleZ]),
            ("wheel_RL", [-l.wheelOffsetX, wheelY, l.rearAxleZ]),
            ("wheel_RR", [l.wheelOffsetX, wheelY, l.rearAxleZ]),
        ]
        for (name, position) in wheels {
            car.addChild(wheel(named: name, at: position, radius: l.wheelRadius, width: l.wheelWidth, p))
        }

        for (name, pivot) in zip(["wiper_L", "wiper_R"], l.wiperPivots) {
            car.addChild(wiper(named: name, at: pivot, length: l.wiperLength, tilt: l.windshieldTilt, p))
        }

        for (name, position) in zip(["headlight_L", "headlight_R"], l.headlights) {
            car.addChild(cylinder(radius: l.headlightRadius, height: 0.012, position, p.headlightOff, axis: .z, name: name))
        }
        for (name, position) in zip(["indicator_FL", "indicator_FR"], l.frontIndicators) {
            car.addChild(box(l.frontIndicatorSize, position, p.indicatorOff, name: name))
        }
        for (name, position) in zip(["indicator_RL", "indicator_RR"], l.rearIndicators) {
            car.addChild(box(l.rearIndicatorSize, position, p.indicatorOff, name: name))
        }
    }

    /// Rad mit Drehpunkt in der Achse. Profilblöcke und Radmuttern machen die Drehung sichtbar.
    private static func wheel(named name: String, at position: SIMD3<Float>, radius: Float, width: Float,
                              _ p: Palette) -> Entity {
        let pivot = Entity()
        pivot.name = name
        pivot.position = position

        pivot.addChild(cylinder(radius: radius, height: width, .zero, p.tire, axis: .x))
        pivot.addChild(cylinder(radius: radius * 0.55, height: width + 0.006, .zero, p.rim, axis: .x))

        let treadCount = 14
        for i in 0..<treadCount {
            let angle = Float(i) / Float(treadCount) * 2 * .pi
            let block = box([width * 0.9, radius * 0.15, radius * 0.26],
                            [0, cos(angle) * radius, sin(angle) * radius], p.tire)
            block.orientation = simd_quatf(angle: angle, axis: [1, 0, 0])
            pivot.addChild(block)
        }

        let nutSize = radius * 0.1
        for side: Float in [-1, 1] {
            for i in 0..<5 {
                let angle = Float(i) / 5 * 2 * .pi
                let x = side * (width / 2 + 0.006)
                pivot.addChild(box([nutSize, nutSize, nutSize],
                                   [x, cos(angle) * radius * 0.3, sin(angle) * radius * 0.3], p.black))
            }
        }
        return pivot
    }

    /// Scheibenwischer mit Drehpunkt am unteren Ende. In Ruhe liegt er waagerecht nach rechts (+x),
    /// gekippt um die Neigung der Scheibe, damit er auf dem Glas wischt.
    private static func wiper(named name: String, at position: SIMD3<Float>, length: Float, tilt: Float,
                              _ p: Palette) -> Entity {
        let pivot = Entity()
        pivot.name = name
        pivot.position = position
        pivot.orientation = simd_quatf(angle: tilt, axis: [1, 0, 0])
        pivot.addChild(box([length, 0.01, 0.008], [length / 2, 0, 0], p.black))
        pivot.addChild(box([length * 0.8, 0.016, 0.006], [length * 0.55, 0.006, -0.006], p.black))
        pivot.addChild(cylinder(radius: 0.012, height: 0.01, .zero, p.black, axis: .z))
        return pivot
    }

    // MARK: - Ersatzmodell aus Grundformen (falls ToyCar.usdz fehlt)

    private static func addProceduralBody(to car: Entity, palette p: Palette) {
        func add(_ size: SIMD3<Float>, _ position: SIMD3<Float>, _ material: SimpleMaterial,
                 corner: Float = 0, yaw: Float = 0) {
            let entity = box(size, position, material, corner: corner)
            entity.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
            car.addChild(entity)
        }

        func addCylinder(radius: Float, height: Float, _ position: SIMD3<Float>, _ material: SimpleMaterial, axis: Axis) {
            car.addChild(cylinder(radius: radius, height: height, position, material, axis: axis))
        }

        // Karosserie
        add([0.40, 0.06, 0.86], [0, 0.15, 0], p.black)                       // Rahmen
        add([0.46, 0.20, 0.88], [0, 0.30, 0], p.sand, corner: 0.02)           // Unterteil mit Motorhaube
        add([0.46, 0.21, 0.58], [0, 0.505, 0.14], p.sand, corner: 0.015)      // Kabine
        for z: Float in [-0.31, 0.31] {
            add([0.58, 0.04, 0.32], [0, 0.285, z], p.black, corner: 0.01)     // Kotflügelverbreiterungen
        }
        for x: Float in [-0.235, 0.235] {
            add([0.02, 0.04, 0.30], [x, 0.22, 0], p.black)                    // Schweller
        }

        // Front
        add([0.52, 0.06, 0.05], [0, 0.20, -0.46], p.black)                    // Stoßstange
        for x: Float in [-0.12, 0.12] {
            add([0.025, 0.13, 0.025], [x, 0.29, -0.47], p.black)              // Rammschutz
        }
        add([0.27, 0.025, 0.025], [0, 0.35, -0.47], p.black)
        add([0.26, 0.09, 0.01], [0, 0.31, -0.443], p.black)                   // Kühlergrill
        add([0.13, 0.035, 0.005], [0, 0.205, -0.488], p.plate)                // Kennzeichen
        for i in 0..<3 {                                                       // Streifen auf der Haube
            add([0.16, 0.004, 0.022], [0.04, 0.402, -0.33 + Float(i) * 0.035], p.black, yaw: 0.6)
        }

        // Heck
        add([0.50, 0.05, 0.04], [0, 0.20, 0.46], p.black)                     // Stoßstange
        for x: Float in [-0.19, 0.19] {
            add([0.045, 0.06, 0.01], [x, 0.33, 0.444], p.tailLight)           // Rückleuchten
        }
        addCylinder(radius: 0.11, height: 0.04, [0, 0.36, 0.46], p.tire, axis: .z)   // Reserverad hinten
        add([0.11, 0.03, 0.004], [0, 0.36, 0.482], p.plate)
        add([0.04, 0.07, 0.035], [0.20, 0.32, 0.465], p.red)                  // Kanister hinten

        // Fenster
        add([0.40, 0.15, 0.01], [0, 0.51, -0.153], p.glass)                   // Windschutzscheibe
        for x: Float in [-0.231, 0.231] {
            for z: Float in [-0.06, 0.13, 0.30] {
                add([0.01, 0.10, 0.13], [x, 0.53, z], p.glass)
            }
        }
        add([0.30, 0.09, 0.01], [0, 0.54, 0.433], p.glass)                    // Heckscheibe

        // Anbauteile
        for x: Float in [-0.26, 0.26] {
            add([0.04, 0.035, 0.015], [x, 0.45, -0.12], p.black)              // Spiegel
        }
        add([0.03, 0.27, 0.03], [0.245, 0.47, -0.17], p.black)                // Schnorchel (rechts)
        add([0.045, 0.03, 0.06], [0.245, 0.615, -0.18], p.black)
        add([0.015, 0.07, 0.36], [-0.255, 0.56, 0.18], p.red)                 // Sandblech (links)

        // Dachträger
        for x: Float in [-0.235, 0.235] {
            add([0.015, 0.015, 0.60], [x, 0.665, 0.14], p.black)
            for z: Float in [-0.16, 0.14, 0.44] {
                add([0.015, 0.06, 0.015], [x, 0.635, z], p.black)
            }
        }
        for z: Float in [-0.16, 0.44] {
            add([0.485, 0.015, 0.015], [0, 0.665, z], p.black)
        }
        for z: Float in [-0.06, 0.06, 0.20, 0.32] {
            add([0.47, 0.01, 0.015], [0, 0.615, z], p.black)
        }

        // Dachladung
        add([0.20, 0.06, 0.17], [0.11, 0.645, -0.05], p.black, corner: 0.01) // Koffer
        addCylinder(radius: 0.04, height: 0.28, [0.13, 0.655, 0.25], p.white, axis: .z)   // Schlafsack
        for z: Float in [0.18, 0.32] {
            addCylinder(radius: 0.042, height: 0.015, [0.13, 0.655, z], p.black, axis: .z)
        }
        addCylinder(radius: 0.10, height: 0.05, [-0.11, 0.64, 0.27], p.tire, axis: .y)    // Ersatzrad
        addCylinder(radius: 0.05, height: 0.052, [-0.11, 0.64, 0.27], p.rim, axis: .y)
        add([0.05, 0.08, 0.07], [0.03, 0.655, 0.39], p.red)                   // Kanister
    }

    // MARK: - Grundformen

    private static func box(_ size: SIMD3<Float>, _ position: SIMD3<Float>, _ material: SimpleMaterial,
                            corner: Float = 0, name: String = "") -> ModelEntity {
        let entity = ModelEntity(mesh: .generateBox(size: size, cornerRadius: corner), materials: [material])
        entity.name = name
        entity.position = position
        return entity
    }

    private static func cylinder(radius: Float, height: Float, _ position: SIMD3<Float>, _ material: SimpleMaterial,
                                 axis: Axis, name: String = "") -> ModelEntity {
        let entity = ModelEntity(mesh: .cylinder(height: height, radius: radius), materials: [material])
        entity.name = name
        entity.position = position
        entity.orientation = axis.cylinderOrientation
        return entity
    }
}
