import RealityKit
import UIKit

/// Animiert die benannten Teile eines Automodells:
/// `wheel_*` drehen sich, `wiper_*` wischen, `headlight_*` und `indicator_*` blinken.
@MainActor
final class CarAnimator {
    private struct Rotating {
        let entity: Entity
        let base: simd_quatf
    }

    private struct Light {
        let entity: ModelEntity
        let offMaterials: [any RealityKit.Material]
        let onMaterials: [any RealityKit.Material]
    }

    private let maxWiperAngle: Float = 1.2
    private let wheelTurnsPerSecond: Float = 0.8
    private let wipesPerSecond: Float = 0.7

    private var wheels: [Rotating] = []
    private var wipers: [Rotating] = []
    private var headlights: [Light] = []
    private var indicators: [Light] = []

    private var time: Float = 0
    private var wheelAngle: Float = 0
    private var wiperPhase: Float = 0
    private var headlightsLit = false
    private var indicatorsLit = false

    init(root: Entity) {
        let headlightColor = UIColor(red: 1, green: 0.96, blue: 0.75, alpha: 1)
        let indicatorColor = UIColor(red: 1, green: 0.6, blue: 0.1, alpha: 1)

        Self.visit(root) { entity in
            let name = entity.name
            if name.hasPrefix("wheel_") {
                wheels.append(Rotating(entity: entity, base: entity.orientation))
            } else if name.hasPrefix("wiper_") {
                wipers.append(Rotating(entity: entity, base: entity.orientation))
            } else if name.hasPrefix("headlight_"), let model = Self.firstModel(in: entity) {
                headlights.append(Self.light(model, color: headlightColor))
            } else if name.hasPrefix("indicator_"), let model = Self.firstModel(in: entity) {
                indicators.append(Self.light(model, color: indicatorColor))
            }
        }
    }

    func update(deltaTime dt: Float, wheels wheelsOn: Bool, wipers wipersOn: Bool, lights lightsOn: Bool) {
        time += dt

        if wheelsOn {
            // Negativer Winkel um die x-Achse = Vorwärtsfahrt (vorne ist -z).
            wheelAngle -= dt * 2 * .pi * wheelTurnsPerSecond
            if wheelAngle < -2 * .pi { wheelAngle += 2 * .pi }
            for wheel in wheels {
                wheel.entity.orientation = wheel.base * simd_quatf(angle: wheelAngle, axis: [1, 0, 0])
            }
        }

        // Beim Ausschalten wischt der Wischer noch zu Ende und bleibt dann unten liegen.
        let cycle = 2 * Float.pi
        if wipersOn || wiperPhase > 0 {
            wiperPhase += dt * cycle * wipesPerSecond
            if wiperPhase >= cycle {
                wiperPhase = wipersOn ? wiperPhase - cycle : 0
            }
            let angle = maxWiperAngle * (1 - cos(wiperPhase)) / 2
            for wiper in wipers {
                wiper.entity.orientation = wiper.base * simd_quatf(angle: angle, axis: [0, 0, 1])
            }
        }

        // Warnblinker im Takt, Scheinwerfer als doppelte Lichthupe alle zwei Sekunden.
        let blink = time.truncatingRemainder(dividingBy: 0.8) < 0.4
        let flash = time.truncatingRemainder(dividingBy: 2)
        let headlightFlash = flash < 0.15 || (flash > 0.3 && flash < 0.45)

        let indicatorsShouldBeLit = lightsOn && blink
        if indicatorsShouldBeLit != indicatorsLit {
            indicatorsLit = indicatorsShouldBeLit
            Self.apply(indicators, lit: indicatorsLit)
        }
        let headlightsShouldBeLit = lightsOn && headlightFlash
        if headlightsShouldBeLit != headlightsLit {
            headlightsLit = headlightsShouldBeLit
            Self.apply(headlights, lit: headlightsLit)
        }
    }

    private static func apply(_ lights: [Light], lit: Bool) {
        for light in lights {
            light.entity.model?.materials = lit ? light.onMaterials : light.offMaterials
        }
    }

    private static func light(_ model: ModelEntity, color: UIColor) -> Light {
        let offMaterials = model.model?.materials ?? []
        let onMaterials = Array(repeating: UnlitMaterial(color: color) as any RealityKit.Material,
                                count: max(1, offMaterials.count))
        return Light(entity: model, offMaterials: offMaterials, onMaterials: onMaterials)
    }

    private static func firstModel(in entity: Entity) -> ModelEntity? {
        if let model = entity as? ModelEntity { return model }
        for child in entity.children {
            if let model = firstModel(in: child) { return model }
        }
        return nil
    }

    private static func visit(_ entity: Entity, _ body: (Entity) -> Void) {
        body(entity)
        for child in entity.children {
            visit(child, body)
        }
    }
}
