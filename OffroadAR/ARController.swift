import ARKit
import Combine
import RealityKit
import UIKit

enum AppMode: String, CaseIterable, Identifiable {
    case play = "Spielen"
    case scan = "Einscannen"

    var id: Self { self }
}

/// Steuert die AR-Session: im Modus „Spielen“ wird das Auto erkannt und das animierte Modell
/// darübergelegt, im Modus „Einscannen“ wird ein neuer Referenz-Scan (`.arobject`) erstellt.
@MainActor
final class ARController: NSObject, ObservableObject {
    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
    let supportsLiDAR = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)

    @Published var mode: AppMode = .play {
        didSet { if mode != oldValue { startSession() } }
    }
    @Published private(set) var status = ""

    // Spielen
    @Published var wheelsOn = true
    @Published var wipersOn = true
    @Published var lightsOn = true
    @Published var environmentOcclusion = false {
        didSet { applyOcclusion() }
    }

    // Einscannen: Breite und Höhe des Kastens folgen aus den Proportionen des 3D-Modells.
    /// Gemessen am echten Auto: 10,2 cm vom Kanister hinten bis zur vorderen Stoßstange.
    @Published var boxLengthCM = 10.2 { didSet { updateScanBox() } }
    @Published var boxYawDegrees = 0.0 { didSet { updateScanBox() } }
    @Published private(set) var boxPlaced = false
    @Published private(set) var pointsInBox = 0
    @Published private(set) var savedScanCount = 0
    @Published private(set) var lastScanURL: URL?

    private let scanBox = ScanBox()
    private let carProportions = CarModelFactory.proportions()
    private var animators: [CarAnimator] = []
    private var updateSubscription: Any?
    private var frameCounter = 0
    private var started = false

    override init() {
        super.init()
        arView.session.delegate = self
        arView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        arView.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
        updateSubscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated {
                self?.tick(deltaTime: Float(event.deltaTime))
            }
        }
        updateScanBox()
        savedScanCount = ScanStore.savedScans().count
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
        animators.removeAll()
        scanBox.remove()
        boxPlaced = false
        pointsInBox = 0

        switch mode {
        case .play:
            runPlaySession()
        case .scan:
            runScanSession()
        }
    }

    private func runPlaySession() {
        arView.debugOptions = []
        let objects = ReferenceObjectLibrary.load()

        let config = ARWorldTrackingConfiguration()
        config.detectionObjects = objects
        config.planeDetection = [.horizontal]
        config.environmentTexturing = .automatic
        if supportsLiDAR {
            config.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            // Hände vor dem Auto verdecken das Modell (geht auch ohne LiDAR ab iPhone XS).
            config.frameSemantics.insert(.personSegmentationWithDepth)
        }
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        applyOcclusion()

        status = objects.isEmpty
            ? "Noch kein Scan vorhanden. Wechsle zu „Einscannen“ und scanne zuerst dein Auto."
            : "Richte die Kamera auf das Auto und bewege dich langsam darum herum."
    }

    private func runScanSession() {
        guard ARObjectScanningConfiguration.isSupported else {
            status = "Dieses iPhone unterstützt das Einscannen von Objekten nicht."
            return
        }
        arView.debugOptions = [.showFeaturePoints]

        let config = ARObjectScanningConfiguration()
        config.planeDetection = [.horizontal]
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        applyOcclusion()

        status = "Stell das Auto auf den Tisch und tippe auf seine Mitte, um den Scan-Kasten zu setzen."
    }

    /// Die Umgebungsverdeckung ist standardmäßig aus: Das LiDAR-Netz ist für ein kleines
    /// Spielzeugauto zu grob und würde das darübergelegte Modell teilweise verschlucken.
    private func applyOcclusion() {
        if mode == .play && supportsLiDAR && environmentOcclusion {
            arView.environment.sceneUnderstanding.options.insert(.occlusion)
        } else {
            arView.environment.sceneUnderstanding.options.remove(.occlusion)
        }
    }

    private func tick(deltaTime: Float) {
        for animator in animators {
            animator.update(deltaTime: deltaTime, wheels: wheelsOn, wipers: wipersOn, lights: lightsOn)
        }
    }

    // MARK: - Spielen

    private func placeCar(on objectAnchor: ARObjectAnchor) {
        let anchorEntity = AnchorEntity(anchor: objectAnchor)
        let car = CarModelFactory.makeCar()
        anchorEntity.addChild(CarModelFactory.fit(car, to: objectAnchor.referenceObject))
        arView.scene.addAnchor(anchorEntity)
        animators.append(CarAnimator(root: car))
        status = "Auto erkannt!"
    }

    // MARK: - Einscannen

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard mode == .scan else { return }
        moveScanBox(to: recognizer.location(in: arView))
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard mode == .scan, boxPlaced else { return }
        moveScanBox(to: recognizer.location(in: arView))
    }

    private func moveScanBox(to point: CGPoint) {
        // Zuerst die erkannte Tischebene (auch unter dem Auto), sonst eine geschätzte Ebene.
        let hit = arView.raycast(from: point, allowing: .existingPlaneInfinite, alignment: .horizontal).first
            ?? arView.raycast(from: point, allowing: .estimatedPlane, alignment: .horizontal).first
        guard let hit else {
            status = "Noch keine Tischfläche erkannt. Bewege das iPhone ein wenig hin und her."
            return
        }
        let column = hit.worldTransform.columns.3
        scanBox.place(at: SIMD3(column.x, column.y, column.z), in: arView.scene)
        if !boxPlaced {
            boxPlaced = true
            status = "Stelle Länge und Drehung so ein, dass der Kasten genau ums Auto passt (rote Kante = vorne). Dann langsam einmal rundherum filmen, auch von oben."
        }
    }

    private func updateScanBox() {
        scanBox.size = carProportions * Float(boxLengthCM) / 100
        scanBox.yaw = Float(boxYawDegrees) * .pi / 180
        scanBox.rebuild()
    }

    private func countFeaturePoints(in frame: ARFrame) {
        guard mode == .scan, boxPlaced else { return }
        frameCounter += 1
        guard frameCounter % 15 == 0 else { return }
        let points = frame.rawFeaturePoints?.points ?? []
        pointsInBox = points.filter { scanBox.contains($0) }.count
    }

    func saveScan() {
        guard let transform = scanBox.worldTransform else { return }
        let size = scanBox.size
        status = "Scan wird berechnet …"
        // Ursprung des Scans = Mitte der Unterseite des Kastens, so steht das Modell später auf dem Tisch.
        arView.session.createReferenceObject(
            transform: transform,
            center: SIMD3(0, size.y / 2, 0),
            extent: size
        ) { [weak self] object, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finishScan(object: object, error: error)
                }
            }
        }
    }

    private func finishScan(object: ARReferenceObject?, error: Error?) {
        guard let object else {
            let reason = error?.localizedDescription ?? "unbekannter Fehler"
            status = "Scan fehlgeschlagen: \(reason). Filme das Auto noch etwas länger von allen Seiten."
            return
        }
        do {
            lastScanURL = try ScanStore.save(object)
            savedScanCount = ScanStore.savedScans().count
            status = "Scan gespeichert! Wechsle zu „Spielen“, um ihn auszuprobieren."
        } catch {
            status = "Speichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    func deleteScans() {
        ScanStore.deleteAll()
        savedScanCount = 0
        lastScanURL = nil
    }
}

extension ARController: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        MainActor.assumeIsolated {
            guard mode == .play else { return }
            for case let objectAnchor as ARObjectAnchor in anchors {
                placeCar(on: objectAnchor)
            }
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        MainActor.assumeIsolated {
            countFeaturePoints(in: frame)
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            status = "AR-Fehler: \(error.localizedDescription)"
        }
    }
}
