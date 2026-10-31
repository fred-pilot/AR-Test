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
    /// Wie viel vom Rundgang ums Auto beim Einlernen geschafft ist (0…1), insgesamt und je Blickhöhe.
    @Published private(set) var scanProgress = 0.0
    @Published private(set) var lowAngleProgress = 0.0
    @Published private(set) var highAngleProgress = 0.0
    /// Größenkorrektur des Modells beim Einlernen (1 = 10,2 cm).
    @Published private(set) var ghostScale: Float = 1
    /// Fehlermeldung oder Hinweis, der die normale Anleitung ersetzt.
    @Published private(set) var message: String?
    /// Zusatzinfo unter der Anleitung, z. B. wie gut die automatische Anpassung passt.
    @Published private(set) var note: String?
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
    let minimumScanProgress = 0.7

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
    /// Rundgang: je 12 Richtungen ringsum, einmal flach von der Seite und einmal schräg von oben.
    private let ringSectors = 12
    /// Schrittweite der Feinjustier-Knöpfe beim Einlernen.
    private let nudgeStep: Float = 0.002
    private let scaleRange: ClosedRange<Float> = 0.8...1.25
    /// Mittlerer Abstand der Messpunkte zum Modell, bis zu dem die automatische Anpassung gilt.
    private let maxFitError: Float = 0.005
    /// Weiter darf die automatische Anpassung das Modell nicht von der Hand-Ausrichtung wegschieben.
    private let maxFitShift: Float = 0.05

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
    private var coveredCells = Set<Int>()
    private var lastPanHit: SIMD3<Float>?
    private var isRotating = false
    private var isPinching = false
    /// Höhe des Bodens (oder Tischs), auf dem das Auto steht.
    private var floorY: Float?
    /// Merkmalspunkte am echten Auto, die ARKit beim Rundgang gefunden hat (nach Kennung, in Weltkoordinaten).
    private var featurePoints: [UInt64: SIMD3<Float>] = [:]
    /// Punkte auf der Oberfläche des Modells, im Koordinatensystem des Geist-Modells.
    private var modelSamples: [SIMD3<Float>] = []
    private var manualPose: simd_float4x4?
    private var lastAutoFit: TimeInterval = 0
    private var fitBusy = false

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
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        for recognizer in [tap, pan, rotate, pinch] as [UIGestureRecognizer] {
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
        note = nil

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
        let scale = mode == .detection ? ReferenceObjectLibrary.learnedScale : 1
        pose.addChild(CarModelFactory.placedAtRealSize(car, scale: scale))
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
        ghostScale = 1
        floorY = nil
        resetScan()
        phase = .placing
    }

    private func resetScan() {
        coveredCells.removeAll()
        scanProgress = 0
        lowAngleProgress = 0
        highAngleProgress = 0
        featurePoints.removeAll()
        modelSamples = []
        manualPose = nil
        lastAutoFit = 0
        note = nil
    }

    private var carSize: SIMD3<Float> { CarModelFactory.realSize * ghostScale }

    /// Höhe des Bodens unter dem angetippten Auto. Der Sehstrahl durchs Auto trifft vielleicht zuerst
    /// eine Fläche auf dem Autodach und erst dahinter den Boden – darum zählt die tiefste Fläche.
    private func floorHeight(at point: CGPoint) -> Float? {
        var results = arView.raycast(from: point, allowing: .existingPlaneGeometry, alignment: .horizontal)
        if results.isEmpty {
            results = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .horizontal)
        }
        return results.map { $0.worldTransform.columns.3.y }.min()
    }

    /// Wo der Sehstrahl durch `point` die halbe Autohöhe erreicht. Dort liegt die Mitte des Autos,
    /// das man antippt – der Boden dahinter wäre ein paar Zentimeter zu weit weg. Zurück kommt der
    /// Punkt auf dem Boden darunter.
    private func carCenterHit(at point: CGPoint) -> SIMD3<Float>? {
        guard let floorY else { return nil }
        let plane = Transform(translation: [0, floorY + carSize.y / 2, 0]).matrix
        guard let hit = arView.unproject(point, ontoPlane: plane) else { return nil }
        return [hit.x, floorY, hit.z]
    }

    /// Nur im ersten Schritt: Antippen setzt das Modell aufs Auto. Danach wird nur noch justiert,
    /// damit ein versehentliches Tippen die Ausrichtung nicht zurücksetzt.
    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard phase == .placing, let camera = arView.session.currentFrame?.camera else { return }
        let point = recognizer.location(in: arView)
        guard let floor = floorHeight(at: point) else {
            message = "Der Boden ist noch nicht erkannt. Beweg das iPhone etwas hin und her und tippe dann noch einmal aufs Auto."
            return
        }
        floorY = floor
        guard let hit = carCenterHit(at: point) else { return }

        // Die Front des Modells zeigt zur Kamera – meist muss man dann nur noch wenig drehen.
        let forward = -SIMD3<Float>(camera.transform.columns.2.x, 0, camera.transform.columns.2.z)
        let yaw = atan2(forward.x, forward.z)
        let transform = Transform(rotation: simd_quatf(angle: yaw, axis: [0, 1, 0]), translation: hit)

        if let ghost {
            ghost.transform = transform
        } else {
            let ghost = AnchorEntity(world: transform.matrix)
            let model = CarModelFactory.placedAtRealSize(CarModelFactory.makeCar(), scale: ghostScale)
            model.components.set(OpacityComponent(opacity: 0.6))
            ghost.addChild(model)
            arView.scene.addAnchor(ghost)
            self.ghost = ghost
        }
        message = nil
        phase = .aligning
    }

    /// Ein Finger verschiebt das Modell um so viel, wie sich der Finger bewegt –
    /// es springt also nicht unter den Finger.
    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard phase == .aligning, let ghost, !isRotating, !isPinching, recognizer.numberOfTouches == 1,
              recognizer.state == .began || recognizer.state == .changed,
              let hit = carCenterHit(at: recognizer.location(in: arView)) else {
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

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            isPinching = true
            lastPanHit = nil
        default:
            isPinching = false
        }
        guard phase == .aligning else { return }
        resizeGhost(by: Float(recognizer.scale))
        recognizer.scale = 1
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

    /// Macht das Modell um `percent` Prozent größer (negativ: kleiner).
    func resizeGhost(percent: Float) {
        guard phase == .aligning else { return }
        resizeGhost(by: 1 + percent / 100)
    }

    private func resizeGhost(by factor: Float) {
        ghostScale = min(scaleRange.upperBound, max(scaleRange.lowerBound, ghostScale * factor))
        ghost?.children.first?.scale = SIMD3(repeating: CarModelFactory.realLength * ghostScale)
    }

    /// Verschiebt das Modell in Millimeterschritten so, wie die Pfeile auf dem Bildschirm zeigen
    /// (`forward` = nach oben auf dem Bildschirm, also vom Betrachter weg; `right` = nach rechts).
    func nudgeGhost(forward: Float, right: Float) {
        guard phase == .aligning, let ghost else { return }
        let center = ghost.position + SIMD3(0, carSize.y / 2, 0)
        guard let screen = arView.project(center) else { return }
        let plane = Transform(translation: [0, center.y, 0]).matrix
        guard let here = arView.unproject(screen, ontoPlane: plane),
              let towardsRight = arView.unproject(CGPoint(x: screen.x + 40, y: screen.y), ontoPlane: plane),
              let towardsTop = arView.unproject(CGPoint(x: screen.x, y: screen.y - 40), ontoPlane: plane)
        else { return }
        let rightward = SIMD2(towardsRight.x - here.x, towardsRight.z - here.z)
        let away = SIMD2(towardsTop.x - here.x, towardsTop.z - here.z)
        guard simd_length(rightward) > 1e-5, simd_length(away) > 1e-5 else { return }
        let move = (simd_normalize(away) * forward + simd_normalize(rightward) * right) * nudgeStep
        ghost.position += SIMD3(move.x, 0, move.y)
    }

    /// Zurück zu Schritt 1: Das nächste Antippen setzt das Modell neu.
    func placeAgain() {
        guard phase == .aligning else { return }
        phase = .placing
    }

    /// „Passt“: Das Modell sitzt ungefähr auf dem Auto, jetzt einmal herumgehen.
    func confirmAlignment() {
        guard phase == .aligning, let ghost, let model = ghost.children.first else { return }
        model.components.set(OpacityComponent(opacity: 0.35))
        resetScan()
        manualPose = ghost.transformMatrix(relativeTo: nil)
        modelSamples = MotionTracker.samples(of: model, relativeTo: ghost, maxCount: 1500).map(\.position)
        message = nil
        phase = .scanning
    }

    /// Zählt, aus welchen Richtungen und Höhen das Auto schon aus passender Nähe gesehen wurde.
    private func updateScanCoverage() {
        guard let ghost, let camera = arView.session.currentFrame?.camera,
              case .normal = camera.trackingState else { return }
        let c = camera.transform.columns.3
        var local = ghost.convert(position: [c.x, c.y, c.z], from: nil)
        local.y -= carSize.y / 2
        let horizontal = simd_length(SIMD2(local.x, local.z))
        let elevation = atan2(local.y, horizontal)
        guard horizontal > 0.05, simd_length(local) < 0.8 else { return }

        let ring: Int
        switch elevation {
        case 0.1..<0.6: ring = 0
        case 0.6..<1.35: ring = 1
        default: return
        }
        let azimuth = atan2(local.x, local.z) + .pi
        let sector = min(ringSectors - 1, Int(azimuth / (2 * .pi) * Float(ringSectors)))
        guard coveredCells.insert(ring * ringSectors + sector).inserted else { return }

        let low = coveredCells.filter { $0 < ringSectors }.count
        lowAngleProgress = Double(low) / Double(ringSectors)
        highAngleProgress = Double(coveredCells.count - low) / Double(ringSectors)
        scanProgress = Double(coveredCells.count) / Double(2 * ringSectors)
        if coveredCells.count == 2 * ringSectors {
            finishScan()
        }
    }

    /// Sammelt Merkmalspunkte in der Nähe des Modells – das ist das echte Auto.
    private func collectFeaturePoints(from frame: ARFrame) {
        guard let ghost, let cloud = frame.rawFeaturePoints else { return }
        let size = carSize
        // Etwas Spielraum, die Hand-Ausrichtung kann ein paar Zentimeter danebenliegen.
        let reach = SIMD2(size.x / 2 + 0.025, size.z / 2 + 0.025)
        let toLocal = ghost.transformMatrix(relativeTo: nil).inverse
        for (point, id) in zip(cloud.points, cloud.identifiers) {
            guard featurePoints.count < 4000 || featurePoints[id] != nil else { continue }
            let local = (toLocal * SIMD4(point, 1)).xyz
            // Der Boden selbst bleibt draußen.
            guard abs(local.x) < reach.x, abs(local.z) < reach.y,
                  local.y > 0.004, local.y < size.y + 0.02 else { continue }
            featurePoints[id] = point
        }
        autoFitIfDue()
    }

    /// Schon während des Rundgangs: Modell an die bisher gefundenen Punkte anpassen, damit man sieht,
    /// ob es passt.
    private func autoFitIfDue() {
        let now = CACurrentMediaTime()
        guard !fitBusy, now - lastAutoFit > 1, featurePoints.count >= 120, scanProgress >= 0.3,
              let ghost else { return }
        lastAutoFit = now
        runAutoFit(from: ghost.transformMatrix(relativeTo: nil), final: false) { _ in }
    }

    private func runAutoFit(from pose: simd_float4x4, final: Bool, completion: @escaping @MainActor (Bool) -> Void) {
        fitBusy = true
        let model = modelSamples, points = Array(featurePoints.values), id = sessionID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = AutoAligner.fit(model: model, pose: pose, points: points, tryReversed: final)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.sessionID == id else { return }
                    self.fitBusy = false
                    completion(self.adoptFit(result, final: final))
                }
            }
        }
    }

    /// Übernimmt die automatische Anpassung, wenn sie gut passt und nicht zu weit von der
    /// Hand-Ausrichtung wegführt.
    private func adoptFit(_ result: AutoAligner.Result?, final: Bool) -> Bool {
        guard phase == (final ? .saving : .scanning),
              let result, let ghost, let manualPose, let floorY,
              result.error < maxFitError, result.matchedPoints >= 40 else { return false }
        var pose = result.pose
        let shift = SIMD2(pose.columns.3.x - manualPose.columns.3.x, pose.columns.3.z - manualPose.columns.3.z)
        guard simd_length(shift) < maxFitShift else { return false }
        // Das Auto steht auf dem Boden: die Höhe nur wenig korrigieren.
        pose.columns.3.y = min(floorY + 0.01, max(floorY - 0.01, pose.columns.3.y))
        if final {
            ghost.transform = Transform(matrix: pose)
        } else {
            ghost.move(to: Transform(matrix: pose), relativeTo: nil, duration: 0.3, timingFunction: .easeInOut)
        }
        note = String(format: "Automatisch angepasst: %.1f mm mittlere Abweichung, %d Messpunkte",
                      result.error * 1000, result.matchedPoints)
        return true
    }

    /// Passt das Modell ein letztes Mal an und erzeugt dann das Referenzobjekt aus allem, was beim
    /// Rundgang in der Box ums Modell gesehen wurde.
    func finishScan() {
        guard phase == .scanning, scanProgress >= minimumScanProgress, let ghost else { return }
        phase = .saving
        runAutoFit(from: ghost.transformMatrix(relativeTo: nil), final: true) { [weak self] adopted in
            self?.createReferenceObject(autoFitted: adopted)
        }
    }

    private func createReferenceObject(autoFitted: Bool) {
        guard phase == .saving, let ghost else { return }
        let size = carSize
        // Etwas Luft zu den Seiten, der Boden selbst bleibt draußen (sonst stört er, wenn das Auto woanders steht).
        let floorGap: Float = 0.003
        let extent = SIMD3(size.x * 1.15, size.y * 1.05, size.z * 1.1)
        let center = SIMD3<Float>(0, floorGap + extent.y / 2, 0)
        let id = sessionID, scale = ghostScale

        arView.session.createReferenceObject(transform: ghost.transformMatrix(relativeTo: nil),
                                             center: center, extent: extent) { [weak self] object, error in
            Task { @MainActor in
                guard let self, self.sessionID == id else { return }
                self.saveLearned(object, error: error, scale: scale, autoFitted: autoFitted)
            }
        }
    }

    private func saveLearned(_ object: ARReferenceObject?, error: Error?, scale: Float, autoFitted: Bool) {
        guard let object else {
            phase = .scanning
            message = "Noch nicht genug vom Auto erkannt (\(error?.localizedDescription ?? "unbekannter Fehler")). Geh noch eine Runde, etwas näher und langsamer."
            return
        }
        do {
            try ReferenceObjectLibrary.saveLearned(object, scale: scale,
                                                   preview: arView.session.currentFrame.flatMap(Self.preview(of:)))
            let summary = autoFitted
                ? "Eingelernt. " + (note ?? "")
                : "Eingelernt, ohne automatische Anpassung (zu wenige Messpunkte am Auto) – deine Ausrichtung gilt."
            startSession()
            note = summary
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
            if phase == .scanning {
                collectFeaturePoints(from: frame)
            } else {
                followMotion(in: frame)
            }
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

    /// Größenkorrektur, mit der das Auto eingelernt wurde.
    static var learnedScale: Float {
        let scale = UserDefaults.standard.float(forKey: scaleKey)
        return scale > 0 ? scale : 1
    }

    static func saveLearned(_ object: ARReferenceObject, scale: Float, preview: UIImage?) throws {
        try FileManager.default.createDirectory(at: learnedURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try object.export(to: learnedURL, previewImage: preview)
        UserDefaults.standard.set(scale, forKey: scaleKey)
    }

    static func deleteLearned() {
        try? FileManager.default.removeItem(at: learnedURL)
        UserDefaults.standard.removeObject(forKey: scaleKey)
    }

    private static let scaleKey = "learnedCarScale"

    private static var learnedURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("ToyCar.arobject")
    }
}
