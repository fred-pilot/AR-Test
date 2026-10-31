import ARKit
import Combine
import CoreImage
import RealityKit
import UIKit

/// Steuert die AR-Session.
///
/// Beim ersten Start lernt die App das Auto einmal ein: Modell antippen und ausrichten, einmal
/// um das Auto herumgehen. Daraus entsteht ein Referenzobjekt (`ToyCar.arobject`), dessen
/// Ursprung genau auf dem ausgerichteten Modell liegt. Ab dann erkennt ARKit das Auto bei jedem
/// Start von selbst, und das animierte Modell sitzt ohne Verschiebung darauf.
///
/// Eingelernte Objekte erkennt ARKit nur, es verfolgt sie nicht Bild für Bild. Bewegt sich das Auto,
/// führt der `MotionTracker` das Modell in Echtzeit nach. ARKit sucht das Auto zusätzlich laufend
/// neu und korrigiert die Lage, sobald es wieder stillsteht.
/// Liegt ein in Create ML trainiertes `ToyCar.referenceobject` in der App, verfolgt ARKit stattdessen
/// dieses selbst in jedem Kamerabild.
@MainActor
final class ARController: NSObject, ObservableObject {
    enum Phase: Equatable {
        case placing, aligning, scanning, saving
        case searching, found, lost
    }

    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
    let supportsLiDAR = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)

    @Published private(set) var phase = Phase.searching
    /// Wie viel vom Rundgang ums Auto beim Einlernen geschafft ist (0…1).
    @Published private(set) var scanProgress = 0.0
    /// Fehlermeldung oder Hinweis, der die normale Anleitung ersetzt.
    @Published private(set) var message: String?
    @Published private(set) var canRelearn = false

    @Published var wheelsOn = true
    @Published var wipersOn = true
    @Published var lightsOn = true
    /// Echtzeit-Nachführen mit dem optischen Fluss (zum Vergleichen abschaltbar).
    @Published var fastFollow = true
    @Published var environmentOcclusion = false {
        didSet { if environmentOcclusion != oldValue && isRunning { startSession() } }
    }

    var isTeaching: Bool { [.placing, .aligning, .scanning, .saving].contains(phase) }
    var isRunning: Bool { !isTeaching }
    var followsWithMotionTracker: Bool { mode == .detection }

    /// Ab so viel Rundgang darf man das Einlernen beenden, bei 100 % geht es von selbst weiter.
    let minimumScanProgress = 0.75

    private enum Mode {
        /// Trainiertes `.referenceobject`: Verfolgung in jedem Kamerabild.
        case tracking
        /// Am iPhone eingelerntes `.arobject`: Erkennung, laufend wiederholt.
        case detection
    }

    /// So lange bleibt das Modell nach einem kurzen Tracking-Aussetzer stehen, bevor es verschwindet.
    private let lostGracePeriod: TimeInterval = 0.5
    /// Nach dieser Zeit wird ein erkanntes Auto vergessen, damit ARKit es neu sucht.
    private let redetectInterval: TimeInterval = 0.8
    /// Kleinere Unterschiede zwischen Erkennung und angezeigter Lage sind Messrauschen.
    private let moveThreshold: Float = 0.004
    private let turnThreshold: Float = 3 * .pi / 180
    /// ARKit-Erkennungen kommen verzögert an. Während das Auto fährt, würden sie es zurückziehen,
    /// darum korrigieren sie erst, wenn es so lange stillsteht.
    private let stillTimeBeforeCorrection: TimeInterval = 0.5
    /// Steht das Auto, wird das Vergleichsbild für den optischen Fluss spätestens so oft erneuert.
    private let keyframeMaxAge: TimeInterval = 0.5
    /// Zeitkonstante, mit der das angezeigte Modell der gemessenen Lage folgt (glättet Zittern).
    private let smoothing: Float = 0.035
    private let scanSectors = 16
    /// Schrittweite der Feinjustier-Knöpfe beim Einlernen.
    private let nudgeStep: Float = 0.002

    private var mode = Mode.detection
    private var sessionID = 0
    private var updateSubscription: Any?
    private var started = false

    /// Das animierte Auto: `worldAnchor` → `carPose` (Lage des echten Autos) → Modell in echter Größe.
    private var worldAnchor: AnchorEntity?
    private var carPose: Entity?
    private var animator: CarAnimator?
    private var lostSince: TimeInterval?
    /// Die gemessene Lage des Autos. Das angezeigte Modell folgt ihr geglättet.
    private var trackedPose: simd_float4x4?

    private var motionTracker: MotionTracker?
    private var keyframe: MotionTracker.Frame?
    private var motionBusy = false
    private var lastMotion: TimeInterval = 0

    /// Das halbdurchsichtige Modell beim Einlernen. Seine Lage wird zum Ursprung des Referenzobjekts.
    private var ghost: AnchorEntity?
    private var coveredSectors = Set<Int>()
    private var lastPanHit: SIMD3<Float>?
    private var isRotating = false

    override init() {
        super.init()
        arView.session.delegate = self
        // Die beweglichen Teile (Räder, Wischer, Lichter) werden von der Umgebung beleuchtet – etwas heller.
        arView.environment.lighting.intensityExponent = 1
        updateSubscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated {
                self?.tick(deltaTime: Float(event.deltaTime))
            }
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
        for recognizer in [tap, pan, rotate] as [UIGestureRecognizer] {
            recognizer.delegate = self
            arView.addGestureRecognizer(recognizer)
        }
    }

    func start() {
        guard !started else { return }
        started = true
        startSession()
    }

    /// „Auto neu suchen“ – oder beim Einlernen: von vorn anfangen.
    func restart() {
        startSession()
    }

    /// Vergisst das eingelernte Auto und startet das Einlernen neu.
    func relearn() {
        ReferenceObjectLibrary.deleteLearned()
        startSession()
    }

    // MARK: - Session

    private func startSession() {
        sessionID += 1
        arView.scene.anchors.removeAll()
        worldAnchor = nil
        carPose = nil
        animator = nil
        trackedPose = nil
        motionTracker = nil
        keyframe = nil
        motionBusy = false
        ghost = nil
        lostSince = nil
        message = nil

        if let trained = ReferenceObjectLibrary.loadTrained() {
            mode = .tracking
            canRelearn = false
            runRecognition(with: trained)
        } else if let learned = ReferenceObjectLibrary.loadLearned() {
            mode = .detection
            canRelearn = true
            runRecognition(with: learned)
        } else {
            mode = .detection
            canRelearn = false
            startTeaching()
        }
    }

    private func runRecognition(with referenceObject: ARReferenceObject) {
        let config = ARWorldTrackingConfiguration()
        switch mode {
        case .tracking:
            // Verfolgung in jedem Kamerabild – das Modell bleibt am Auto, auch wenn es geschoben wird.
            config.trackingObjects = [referenceObject]
        case .detection:
            config.detectionObjects = [referenceObject]
        }
        if let format = Self.fastestVideoFormat() {
            config.videoFormat = format
        }
        config.environmentTexturing = .automatic
        if supportsLiDAR && environmentOcclusion {
            config.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            // Hände vor dem Auto verdecken das Modell (geht auch ohne LiDAR ab iPhone XS).
            config.frameSemantics.insert(.personSegmentationWithDepth)
        }
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        applyOcclusion()

        let anchor = AnchorEntity(world: matrix_identity_float4x4)
        let pose = Entity()
        let car = CarModelFactory.makeCar()
        pose.addChild(CarModelFactory.placedAtRealSize(car))
        pose.isEnabled = false
        anchor.addChild(pose)
        arView.scene.addAnchor(anchor)
        worldAnchor = anchor
        carPose = pose
        animator = CarAnimator(root: car)
        if mode == .detection {
            motionTracker = MotionTracker(samples: MotionTracker.samples(of: car, relativeTo: pose))
        }

        phase = .searching
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
        if supportsLiDAR && environmentOcclusion && isRunning {
            arView.environment.sceneUnderstanding.options.insert(.occlusion)
        } else {
            arView.environment.sceneUnderstanding.options.remove(.occlusion)
        }
    }

    private func tick(deltaTime: Float) {
        if phase == .scanning {
            updateScanCoverage()
        }
        if mode == .tracking, let lostSince, CACurrentMediaTime() - lostSince > lostGracePeriod {
            carPose?.isEnabled = false
        }
        if mode == .detection, let target = trackedPose, let carPose {
            let goal = Transform(matrix: target)
            let k = 1 - exp(-deltaTime / smoothing)
            var shown = carPose.transform
            shown.translation = simd_mix(shown.translation, goal.translation, SIMD3(repeating: k))
            shown.rotation = simd_slerp(shown.rotation, goal.rotation, k)
            carPose.transform = shown
        }
        animator?.update(deltaTime: deltaTime, wheels: wheelsOn, wipers: wipersOn, lights: lightsOn)
    }

    /// Nur bei Änderung setzen, sonst würde die Oberfläche bei jedem Kamerabild neu gezeichnet.
    private func setPhase(_ newPhase: Phase) {
        if phase != newPhase { phase = newPhase }
    }

    // MARK: - Erkennen

    private func handle(_ objectAnchor: ARObjectAnchor, isNew: Bool) {
        guard let carPose else { return }
        switch mode {
        case .tracking:
            if objectAnchor.isTracked {
                carPose.transform = Transform(matrix: objectAnchor.transform)
                carPose.isEnabled = true
                lostSince = nil
                setPhase(.found)
            } else if lostSince == nil {
                lostSince = CACurrentMediaTime()
                setPhase(.lost)
            }
        case .detection:
            guard isNew else { return }
            correct(to: objectAnchor.transform)
            carPose.isEnabled = true
            setPhase(.found)
            forgetLater(objectAnchor)
        }
    }

    /// Erste Erkennung: sofort hinsetzen. Danach nur korrigieren, wenn das Auto steht und die
    /// Erkennung deutlich von der nachgeführten Lage abweicht.
    private func correct(to detected: simd_float4x4) {
        guard let current = trackedPose else {
            trackedPose = detected
            carPose?.transform = Transform(matrix: detected)
            return
        }
        if fastFollow && CACurrentMediaTime() - lastMotion < stillTimeBeforeCorrection { return }
        let a = Transform(matrix: current), b = Transform(matrix: detected)
        let distance = simd_distance(a.translation, b.translation)
        let delta = simd_mul(a.rotation.inverse, b.rotation)
        let angle = 2 * acos(min(1, abs(delta.real)))
        guard distance > moveThreshold || angle > turnThreshold else { return }
        trackedPose = detected
        // Das Vergleichsbild gehört zur alten Lage – neu anfangen.
        keyframe = nil
    }

    /// ARKit meldet ein eingelerntes Objekt nur einmal und hält es dann fest. Wird der Anker
    /// entfernt, sucht ARKit das Auto neu und findet es an der aktuellen Stelle.
    private func forgetLater(_ anchor: ARObjectAnchor) {
        let id = sessionID
        DispatchQueue.main.asyncAfter(deadline: .now() + redetectInterval) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.sessionID == id else { return }
                self.arView.session.remove(anchor: anchor)
            }
        }
    }

    // MARK: - Echtzeit-Nachführen

    private func followMotion(in frame: ARFrame) {
        guard mode == .detection, fastFollow, phase == .found, !motionBusy,
              let pose = trackedPose, let motionTracker,
              case .normal = frame.camera.trackingState else { return }
        let current = MotionTracker.Frame(image: frame.capturedImage, camera: frame.camera, time: frame.timestamp)
        guard let keyframe else {
            self.keyframe = current
            return
        }
        motionBusy = true
        let id = sessionID
        motionTracker.track(from: keyframe, to: current, pose: pose) { [weak self] outcome in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.sessionID == id else { return }
                    self.motionBusy = false
                    self.apply(outcome, at: current)
                }
            }
        }
    }

    private func apply(_ outcome: MotionTracker.Outcome, at frame: MotionTracker.Frame) {
        switch outcome {
        case .moved(let delta):
            if let pose = trackedPose {
                trackedPose = delta * pose
            }
            keyframe = frame
            lastMotion = CACurrentMediaTime()
        case .still:
            // Vergleichsbild behalten, so summieren sich auch langsame Bewegungen über die Rauschschwelle.
            if let keyframe, frame.time - keyframe.time > keyframeMaxAge {
                self.keyframe = frame
            }
        case .lost:
            keyframe = frame
        }
    }

    // MARK: - Einlernen

    private func startTeaching() {
        guard ARObjectScanningConfiguration.isSupported else {
            phase = .placing
            message = "Dieses iPhone kann keine Objekte einlernen."
            return
        }
        let config = ARObjectScanningConfiguration()
        config.planeDetection = .horizontal
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        applyOcclusion()
        coveredSectors.removeAll()
        scanProgress = 0
        phase = .placing
    }

    /// Nur im ersten Schritt: Antippen setzt das Modell aufs Auto. Danach wird nur noch justiert,
    /// damit ein versehentliches Tippen die Ausrichtung nicht zurücksetzt.
    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard phase == .placing,
              let hit = floorHit(at: recognizer.location(in: arView)),
              let camera = arView.session.currentFrame?.camera else { return }

        // Die Front des Modells zeigt zur Kamera – meist muss man dann nur noch wenig drehen.
        let forward = -SIMD3<Float>(camera.transform.columns.2.x, 0, camera.transform.columns.2.z)
        let yaw = atan2(forward.x, forward.z)
        let transform = Transform(rotation: simd_quatf(angle: yaw, axis: [0, 1, 0]), translation: hit)

        if let ghost {
            ghost.transform = transform
        } else {
            let ghost = AnchorEntity(world: transform.matrix)
            let model = CarModelFactory.placedAtRealSize(CarModelFactory.makeCar())
            model.components.set(OpacityComponent(opacity: 0.6))
            ghost.addChild(model)
            arView.scene.addAnchor(ghost)
            self.ghost = ghost
        }
        message = nil
        phase = .aligning
    }

    /// Ein Finger verschiebt das Modell um so viel, wie sich der Finger auf dem Boden bewegt –
    /// es springt also nicht unter den Finger.
    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard phase == .aligning, let ghost, !isRotating, recognizer.numberOfTouches == 1,
              recognizer.state == .began || recognizer.state == .changed,
              let hit = floorHit(at: recognizer.location(in: arView)) else {
            lastPanHit = nil
            return
        }
        if let last = lastPanHit {
            ghost.position += SIMD3(hit.x - last.x, 0, hit.z - last.z)
        }
        lastPanHit = hit
    }

    @objc private func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            isRotating = true
            lastPanHit = nil
        default:
            isRotating = false
        }
        guard phase == .aligning else { return }
        // Bildschirm-Drehung im Uhrzeigersinn = Drehung im Uhrzeigersinn von oben gesehen.
        rotateGhost(by: -Float(recognizer.rotation))
        recognizer.rotation = 0
    }

    /// Dreht das Modell gegen den Uhrzeigersinn (von oben gesehen), in Grad.
    func rotateGhost(degrees: Float) {
        guard phase == .aligning else { return }
        rotateGhost(by: degrees * .pi / 180)
    }

    private func rotateGhost(by angle: Float) {
        guard let ghost else { return }
        ghost.orientation = simd_quatf(angle: angle, axis: [0, 1, 0]) * ghost.orientation
    }

    /// Verschiebt das Modell in Millimeterschritten, bezogen auf die Blickrichtung der Kamera
    /// (`forward` = vom Betrachter weg, `right` = nach rechts).
    func nudgeGhost(forward: Float, right: Float) {
        guard phase == .aligning, let ghost, let camera = arView.session.currentFrame?.camera else { return }
        let back = camera.transform.columns.2, side = camera.transform.columns.0
        let ahead = simd_normalize(SIMD2(-back.x, -back.z))
        let rightward = simd_normalize(SIMD2(side.x, side.z))
        let move = (ahead * forward + rightward * right) * nudgeStep
        ghost.position += SIMD3(move.x, 0, move.y)
    }

    /// Zurück zu Schritt 1: Das nächste Antippen setzt das Modell neu.
    func placeAgain() {
        guard phase == .aligning else { return }
        phase = .placing
    }

    private func floorHit(at point: CGPoint) -> SIMD3<Float>? {
        guard let result = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .horizontal).first
        else { return nil }
        let c = result.worldTransform.columns.3
        return [c.x, c.y, c.z]
    }

    /// „Passt“: Das Modell sitzt auf dem Auto, jetzt einmal herumgehen.
    func confirmAlignment() {
        guard phase == .aligning, let ghost else { return }
        ghost.children.first?.components.set(OpacityComponent(opacity: 0.25))
        coveredSectors.removeAll()
        scanProgress = 0
        message = nil
        phase = .scanning
    }

    /// Zählt, aus welchen Richtungen das Auto schon aus passender Nähe gesehen wurde.
    private func updateScanCoverage() {
        guard let ghost, let camera = arView.session.currentFrame?.camera,
              case .normal = camera.trackingState else { return }
        let c = camera.transform.columns.3
        let local = ghost.convert(position: [c.x, c.y, c.z], from: nil)
        let horizontal = simd_length(SIMD2(local.x, local.z))
        let elevation = atan2(local.y, horizontal)
        guard horizontal > 0.08, horizontal < 0.8, elevation > 0.1, elevation < 1.4 else { return }

        let azimuth = atan2(local.x, local.z) + .pi
        let sector = min(scanSectors - 1, Int(azimuth / (2 * .pi) * Float(scanSectors)))
        guard coveredSectors.insert(sector).inserted else { return }
        scanProgress = Double(coveredSectors.count) / Double(scanSectors)
        if coveredSectors.count == scanSectors {
            finishScan()
        }
    }

    /// Erzeugt das Referenzobjekt aus allem, was beim Rundgang in der Box ums Modell gesehen wurde.
    func finishScan() {
        guard phase == .scanning, scanProgress >= minimumScanProgress, let ghost else { return }
        phase = .saving

        let size = CarModelFactory.realSize
        // Etwas Luft zu den Seiten, der Boden selbst bleibt draußen (sonst stört er, wenn das Auto woanders steht).
        let floorGap: Float = 0.003
        let extent = SIMD3(size.x * 1.15, size.y * 1.05, size.z * 1.1)
        let center = SIMD3<Float>(0, floorGap + extent.y / 2, 0)
        let id = sessionID

        arView.session.createReferenceObject(transform: ghost.transformMatrix(relativeTo: nil),
                                             center: center, extent: extent) { [weak self] object, error in
            Task { @MainActor in
                guard let self, self.sessionID == id else { return }
                self.saveLearned(object, error: error)
            }
        }
    }

    private func saveLearned(_ object: ARReferenceObject?, error: Error?) {
        guard let object else {
            phase = .scanning
            message = "Noch nicht genug vom Auto erkannt (\(error?.localizedDescription ?? "unbekannter Fehler")). Geh noch eine Runde, etwas näher und langsamer."
            return
        }
        do {
            try ReferenceObjectLibrary.saveLearned(object, preview: arView.session.currentFrame.flatMap(Self.preview(of:)))
            startSession()
        } catch {
            phase = .scanning
            message = "Speichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private static func preview(of frame: ARFrame) -> UIImage? {
        let image = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        guard let cgImage = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

extension ARController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

extension ARController: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        MainActor.assumeIsolated {
            followMotion(in: frame)
        }
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        MainActor.assumeIsolated {
            for case let objectAnchor as ARObjectAnchor in anchors {
                handle(objectAnchor, isNew: true)
            }
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        MainActor.assumeIsolated {
            for case let objectAnchor as ARObjectAnchor in anchors {
                handle(objectAnchor, isNew: false)
            }
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            message = "AR-Fehler: \(error.localizedDescription)"
        }
    }
}

/// Lädt und speichert die Referenzobjekte des Autos.
enum ReferenceObjectLibrary {
    /// In Create ML trainiert und in die App gepackt (optional, verfolgt das Auto in jedem Bild).
    static func loadTrained() -> ARReferenceObject? {
        guard let url = Bundle.main.url(forResource: "ToyCar", withExtension: "referenceobject") else { return nil }
        return try? ARReferenceObject(archiveURL: url)
    }

    /// Beim Einlernen am iPhone entstanden, liegt in den App-Daten.
    static func loadLearned() -> ARReferenceObject? {
        guard FileManager.default.fileExists(atPath: learnedURL.path) else { return nil }
        return try? ARReferenceObject(archiveURL: learnedURL)
    }

    static func saveLearned(_ object: ARReferenceObject, preview: UIImage?) throws {
        try FileManager.default.createDirectory(at: learnedURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try object.export(to: learnedURL, previewImage: preview)
    }

    static func deleteLearned() {
        try? FileManager.default.removeItem(at: learnedURL)
    }

    private static var learnedURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("ToyCar.arobject")
    }
}
