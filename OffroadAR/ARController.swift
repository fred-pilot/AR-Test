import ARKit
import Combine
import RealityKit
import UIKit

/// Steuert die AR-Session: ARKit erkennt das Auto anhand des trainierten 3D-Modells
/// (`ToyCar.referenceobject`) und verfolgt es in jedem Kamerabild. Das animierte Modell
/// hängt direkt am erkannten Auto, Lage, Drehung und Höhe kommen von ARKit.
@MainActor
final class ARController: NSObject, ObservableObject {
    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
    let supportsLiDAR = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)

    /// Wird nur bei Änderung neu gesetzt, sonst würde die Oberfläche bei jedem Kamerabild neu gezeichnet.
    @Published private(set) var status = ""

    @Published var wheelsOn = true
    @Published var wipersOn = true
    @Published var lightsOn = true
    @Published var environmentOcclusion = false {
        didSet { if environmentOcclusion != oldValue { startSession() } }
    }

    /// So lange bleibt das Modell nach einem kurzen Tracking-Aussetzer stehen, bevor es verschwindet.
    /// Verhindert Flackern, wenn das Auto für einen Moment verdeckt ist oder die Kamera wackelt.
    private let lostGracePeriod: TimeInterval = 0.5

    private struct TrackedCar {
        let anchor: AnchorEntity
        let animator: CarAnimator
        var lostSince: TimeInterval?
    }

    private let referenceObject = ReferenceObjectLibrary.load()
    private var cars: [UUID: TrackedCar] = [:]
    private var updateSubscription: Any?
    private var started = false

    override init() {
        super.init()
        arView.session.delegate = self
        updateSubscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated {
                self?.tick(deltaTime: Float(event.deltaTime))
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        startSession()
    }

    func restart() {
        startSession()
    }

    // MARK: - Session

    private func startSession() {
        arView.scene.anchors.removeAll()
        cars.removeAll()

        guard let referenceObject else {
            status = "Das trainierte Automodell (ToyCar.referenceobject) fehlt in der App."
            return
        }

        let config = ARWorldTrackingConfiguration()
        // Verfolgung in jedem Kamerabild – das Modell bleibt am Auto, auch wenn es geschoben wird.
        config.trackingObjects = [referenceObject]
        config.environmentTexturing = .automatic
        if let format = Self.fastestVideoFormat() {
            config.videoFormat = format
        }
        if supportsLiDAR && environmentOcclusion {
            config.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            // Hände vor dem Auto verdecken das Modell (geht auch ohne LiDAR ab iPhone XS).
            config.frameSemantics.insert(.personSegmentationWithDepth)
        }
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        applyOcclusion()

        status = "Richte die Kamera auf das Auto."
    }

    /// Das Videoformat mit der höchsten Bildrate (bei gleicher Rate das größere Bild).
    private static func fastestVideoFormat() -> ARConfiguration.VideoFormat? {
        ARWorldTrackingConfiguration.supportedVideoFormats.max { a, b in
            if a.framesPerSecond != b.framesPerSecond { return a.framesPerSecond < b.framesPerSecond }
            return a.imageResolution.width < b.imageResolution.width
        }
    }

    /// Die Umgebungsverdeckung ist standardmäßig aus: Das LiDAR-Netz ist für ein kleines
    /// Spielzeugauto zu grob und würde das darübergelegte Modell teilweise verschlucken.
    private func applyOcclusion() {
        if supportsLiDAR && environmentOcclusion {
            arView.environment.sceneUnderstanding.options.insert(.occlusion)
        } else {
            arView.environment.sceneUnderstanding.options.remove(.occlusion)
        }
    }

    private func tick(deltaTime: Float) {
        let now = CACurrentMediaTime()
        for car in cars.values {
            if let lostSince = car.lostSince, now - lostSince > lostGracePeriod {
                car.anchor.isEnabled = false
            }
            car.animator.update(deltaTime: deltaTime, wheels: wheelsOn, wipers: wipersOn, lights: lightsOn)
        }
    }

    // MARK: - Auto

    private func placeCar(on objectAnchor: ARObjectAnchor) {
        let anchorEntity = AnchorEntity(anchor: objectAnchor)
        let car = CarModelFactory.makeCar()
        anchorEntity.addChild(CarModelFactory.placedAtRealSize(car))
        arView.scene.addAnchor(anchorEntity)
        cars[objectAnchor.identifier] = TrackedCar(anchor: anchorEntity, animator: CarAnimator(root: car))
        updateTracking(of: objectAnchor)
    }

    private func updateTracking(of objectAnchor: ARObjectAnchor) {
        guard var car = cars[objectAnchor.identifier] else { return }
        if objectAnchor.isTracked {
            car.lostSince = nil
            car.anchor.isEnabled = true
            setStatus("Auto erkannt!")
        } else if car.lostSince == nil {
            car.lostSince = CACurrentMediaTime()
            setStatus("Auto aus dem Blick – richte die Kamera wieder darauf.")
        }
        cars[objectAnchor.identifier] = car
    }

    private func setStatus(_ text: String) {
        if status != text { status = text }
    }
}

extension ARController: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        MainActor.assumeIsolated {
            for case let objectAnchor as ARObjectAnchor in anchors {
                placeCar(on: objectAnchor)
            }
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        MainActor.assumeIsolated {
            for case let objectAnchor as ARObjectAnchor in anchors {
                updateTracking(of: objectAnchor)
            }
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            status = "AR-Fehler: \(error.localizedDescription)"
        }
    }
}

/// Lädt das in Create ML trainierte Referenzobjekt des Autos aus dem App-Bundle.
enum ReferenceObjectLibrary {
    static func load() -> ARReferenceObject? {
        guard let url = Bundle.main.url(forResource: "ToyCar", withExtension: "referenceobject") else { return nil }
        return try? ARReferenceObject(archiveURL: url)
    }
}
