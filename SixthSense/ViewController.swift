import UIKit
import ARKit
import Vision
import CoreML
import AVFoundation

struct WavepointSummary: Codable {
    let number: Int
    let distance: Float
    let angle: Float
}

class DataManager {
    static let shared = DataManager()
    
    private let userDefaults = UserDefaults.standard
    private let savedDataKey = "SavedLocationData"
    
    private init() {}
    
    func saveData(label: String, wavepointSummaries: [WavepointSummary]) {
        var savedData = getSavedData()
        savedData[label] = wavepointSummaries
        userDefaults.set(try? PropertyListEncoder().encode(savedData), forKey: savedDataKey)
    }
    
    func getSavedData() -> [String: [WavepointSummary]] {
        guard let data = userDefaults.data(forKey: savedDataKey),
              let savedData = try? PropertyListDecoder().decode([String: [WavepointSummary]].self, from: data) else {
            return [:]
        }
        return savedData
    }
}

class SavedDataViewController: UITableViewController {
    private var savedData: [String: [WavepointSummary]] = [:]
    private var locations: [String] = []
    
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Saved Locations"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "LocationCell")
        loadSavedData()
    }
    
    private func loadSavedData() {
        savedData = DataManager.shared.getSavedData()
        locations = Array(savedData.keys).sorted()
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return locations.count
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "LocationCell", for: indexPath)
        cell.textLabel?.text = locations[indexPath.row]
        return cell
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let location = locations[indexPath.row]
        if let wavepointSummaries = savedData[location] {
            showWavepointSummary(for: location, summaries: wavepointSummaries)
        }
    }
    
    private func showWavepointSummary(for location: String, summaries: [WavepointSummary]) {
        let alertController = UIAlertController(title: "Wavepoint Summary: \(location)", message: "", preferredStyle: .alert)
        
        var message = ""
        for summary in summaries {
            message += "Wavepoint \(summary.number):\n"
            message += "  Distance: \(String(format: "%.2f", summary.distance)) cm\n"
            message += "  Angle: \(String(format: "%.2f", summary.angle))°\n\n"
        }
        
        alertController.message = message
        
        alertController.addAction(UIAlertAction(title: "Take Me There", style: .default) { [weak self] _ in
            self?.navigateToLocation(location: location, summaries: summaries)
        })
        
        alertController.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alertController, animated: true)
    }
    
    private func navigateToLocation(location: String, summaries: [WavepointSummary]) {
        let navigationVC = NavigationViewController(location: location, wavepointSummaries: summaries)
        navigationController?.pushViewController(navigationVC, animated: true)
    }
}

class NavigationViewController: UIViewController, ARSessionDelegate, AVSpeechSynthesizerDelegate {
    private let location: String
    private let wavepointSummaries: [WavepointSummary]
    private var currentWavepointIndex = 0
    private let speechSynthesizer = AVSpeechSynthesizer()
    
    private var arSession: ARSession!
    private var sceneView: ARSCNView!
    
    private var startPosition: simd_float3?
    private var lastPosition: simd_float3?
    private var totalDistance: Float = 0
    private var currentAngle: Float = 0
    private var isTurning = false
    private var targetAngle: Float = 0
    private var destinationReachedAnnounced = false
    private var isSpeaking = false
    
    private var overshootDistance: Float = 0
    private var overshootStartPosition: simd_float3?
    
    private var lastAngleAnnouncementTime: Date?
    private var lastAngleRange: ClosedRange<Float>?
    
    private var lastAnnouncementTime: Date?
    private let announcementInterval: TimeInterval = 2.0
    private let overshootThreshold: Float = 0.25
    private let remainingThreshold: Float = 0.25
    
    private var hasTurnBeenAnnounced = false
    private var hasReached45DegreeTurn = false
    
    private var initialForwardVector: simd_float3?
    private var turnStartForwardVector: simd_float3?
    
    private var isTracking = false
    private var isInWavepoint = false
    private var cumulativeDistance: Float = 0
    private var lastRecordedAngle: Float = 0
    
    private var hasPreparedForTurn = false
    private var hasAnnouncedTurn = false
    private var turnAnnouncementTime: Date?
    
    private var hasAnnounced5Feet = false
    private var hasAnnounced1Foot = false
    private var isInTurnZone = false
    
    private var angleToTurn: Float = 0
    private var turnStartAngle: Float = 0
    private var angleTurned: Float = 0
    
    private var turnCompletionTimer: Timer?
    private var isInTurnCompletionRange = false
    
    private var isMeasuringAngle = false
    private var turnStartTime: Date?
    private var lastAngleCorrectionTime: Date?
    
    private var initialTurnAngle: Float = 0
    
    private var lastAngleCheckTime: Date?
    private var lastCheckedAngle: Float = 0
    
    private var lastTurnInstructionTime: Date?
    
    private var angleCheckStartTime: Date?
    private var currentAngleZone: AngleZone = .neutral
    
    private var shouldUpdateAngle = false
    
    private var rightTurnCompletionTimer: Timer?
    private var rightTurnCompletionStartTime: Date?
    private var turnCompletionStartTime: Date?
    
    private var initialTurnInstructionGiven: Bool = false
    private var turnInstructionStartTime: Date?
    
    private var currentWavepointStartPosition: simd_float3?
    private var currentWavepointDistance: Float = 0
    private var remainingDistance: Float = 0
    private var hasCrossedDistanceThreshold: Bool = false
    
    private let turnInstructionInterval: TimeInterval = 4.0
        
    private enum AngleZone {
        case belowTarget
        case onTarget
        case aboveTarget
        case neutral
    }
    
    private let instructionLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .white
        label.font = UIFont.systemFont(ofSize: 18)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        return label
    }()
    
    private let angleCounterLabel: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.textColor = .white
        label.font = UIFont.systemFont(ofSize: 24)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        return label
    }()
    
    private let angleLabel: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.textColor = .white
        label.font = UIFont.systemFont(ofSize: 24)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        return label
    }()
    
    private let distanceLabel: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.textColor = .white
        label.font = UIFont.systemFont(ofSize: 18)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        return label
    }()
    
    private let overshootLabel: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.textColor = .white
        label.font = UIFont.systemFont(ofSize: 18)
        label.backgroundColor = UIColor.red.withAlphaComponent(0.7)
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        return label
    }()
    
    init(location: String, wavepointSummaries: [WavepointSummary]) {
        self.location = location
        self.wavepointSummaries = wavepointSummaries
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupAR()
        setupUI()
        setupAudioSession()
        speechSynthesizer.delegate = self
        startNavigation()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        arSession.run(ARWorldTrackingConfiguration())
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        arSession.pause()
    }
    
    private func setupAR() {
        arSession = ARSession()
        arSession.delegate = self
        
        sceneView = ARSCNView(frame: view.bounds)
        sceneView.session = arSession
        view.addSubview(sceneView)
    }
    
    private func setupUI() {
        view.addSubview(instructionLabel)
        view.addSubview(angleLabel)
        view.addSubview(distanceLabel)
        
        instructionLabel.translatesAutoresizingMaskIntoConstraints = false
        angleLabel.translatesAutoresizingMaskIntoConstraints = false
        distanceLabel.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            instructionLabel.bottomAnchor.constraint(equalTo: distanceLabel.topAnchor, constant: -10),
            instructionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            instructionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            angleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            angleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            angleLabel.widthAnchor.constraint(equalToConstant: 100),
            angleLabel.heightAnchor.constraint(equalToConstant: 40),
            
            distanceLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            distanceLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            distanceLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            distanceLabel.heightAnchor.constraint(equalToConstant: 40)
        ])
    }
    
    private func setupAudioSession() {
         do {
             try AVAudioSession.sharedInstance().setCategory(AVAudioSessionCategoryPlayback)
             try AVAudioSession.sharedInstance().setActive(true)
         } catch {
             print("Failed to set audio session category: \(error)")
         }
     }
    

    private func startNavigation() {
        guard currentWavepointIndex < wavepointSummaries.count else {
            destinationReached()
            return
        }
        prepareForNextWaypoint()
        announceNextWaypoint()
    }
    
    private func prepareForNextWaypoint() {
        guard currentWavepointIndex < wavepointSummaries.count else {
            destinationReached()
            return
        }

        let waypoint = wavepointSummaries[currentWavepointIndex]
        currentWavepointDistance = 0
        remainingDistance = waypoint.distance
        hasCrossedDistanceThreshold = false
        initialTurnInstructionGiven = false
        turnInstructionStartTime = nil
        isMeasuringAngle = false
        hasAnnounced5Feet = false
        hasAnnounced1Foot = false
        totalDistance = 0
        currentAngle = 0
        updateDistanceLabel(distance: waypoint.distance)
        currentWavepointStartPosition = lastPosition
        turnStartTime = nil
        lastAngleCorrectionTime = nil
        initialTurnAngle = 0
        initialForwardVector = nil
        isInTurnZone = false
        targetAngle = waypoint.angle
    }
    
    private func announceNextWaypoint() {
        let waypoint = wavepointSummaries[currentWavepointIndex]
        let turnDirection = waypoint.angle < 0 ? "right" : "left"
        let instruction = "Walk forward \(String(format: "%.1f", cmToFeet(waypoint.distance))) feet, then turn \(turnDirection)."
        speakInstruction(instruction)
        updateInstructionLabel(instruction)
        updateDistanceLabel(distance: waypoint.distance)
        
        if let frame = sceneView.session.currentFrame {
            initialForwardVector = simd_float3(-frame.camera.transform.columns.2.x,
                                               -frame.camera.transform.columns.2.y,
                                               -frame.camera.transform.columns.2.z)
        }
    }
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let currentPosition = simd_float3(
            frame.camera.transform.columns.3.x,
            frame.camera.transform.columns.3.y,
            frame.camera.transform.columns.3.z
        )
        
        if startPosition == nil {
            startPosition = currentPosition
            lastPosition = currentPosition
            currentWavepointStartPosition = currentPosition
            initialForwardVector = simd_float3(-frame.camera.transform.columns.2.x,
                                               -frame.camera.transform.columns.2.y,
                                               -frame.camera.transform.columns.2.z)
            return
        }
        
        updateAngle(frame)
        handleWalking(currentPosition)
        
        lastPosition = currentPosition
    }
    
    
    private func updateAngleLabel() {
        DispatchQueue.main.async {
            self.angleLabel.text = String(format: "%.1f", self.currentAngle)
        }
    }
    
    private func updateAngle(_ frame: ARFrame) {
        guard let initialForward = initialForwardVector else { return }
        
        let currentForward = -frame.camera.transform.columns.2
        let angle = atan2(currentForward.x, currentForward.z) - atan2(initialForward.x, initialForward.z)
        currentAngle = (angle * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        currentAngle = currentAngle > 180 ? currentAngle - 360 : currentAngle
        
        updateAngleLabel()
        checkAngleRequirements()
    }
    

    
    private func handleWalking(_ currentPosition: simd_float3) {
        guard currentWavepointIndex < wavepointSummaries.count else {
            destinationReached()
            return
        }

        guard let startPos = currentWavepointStartPosition else { return }
        
        let movement = currentPosition - startPos
        let forwardMovement = simd_length(movement)
        currentWavepointDistance = forwardMovement * 100
        
        let waypoint = wavepointSummaries[currentWavepointIndex]
        let remainingDistance = max(0, waypoint.distance - currentWavepointDistance)
        let remainingFeet = cmToFeet(remainingDistance)
        
        updateDistanceLabel(distance: remainingFeet)
        
        checkTurnZone(remainingDistance: remainingFeet)
        
        if isInTurnZone {
            checkAngleRequirements()
        }

        if remainingDistance <= 0.1 && !isInTurnZone {
            completeWaypoint()
        }
    }
    
    private func checkTurnZone(remainingDistance: Float) {
        let turnThreshold: Float = 0.25
        
        if remainingDistance <= turnThreshold && !isInTurnZone {
            isInTurnZone = true
            announceTurn()
        }
    }
    
    private func startMeasuringAngle() {
        isMeasuringAngle = true
        turnStartTime = Date()
        speakInstruction("Start turning", rate: 0.4)
        
        if let frame = sceneView.session.currentFrame {
            initialTurnAngle = getCurrentAngle(frame)
        } else {
            initialTurnAngle = currentAngle
            print("Warning: Unable to get current frame. Using last known angle: \(initialTurnAngle)")
        }
        
        print("Initial turn angle set to: \(initialTurnAngle)")
    }
    
    
    private func announceTurn() {
        if !hasTurnBeenAnnounced {
            let turnDirection = targetAngle < 0 ? "right" : "left"
            speakInstruction("Turn \(turnDirection)")
            hasTurnBeenAnnounced = true
            lastTurnInstructionTime = Date()
        }
    }

    
    private func announceProgress(remainingDistance: Float) {
        let remainingFeet = cmToFeet(remainingDistance)

        if !hasAnnounced5Feet && remainingFeet <= 5 && remainingFeet > 4 {
            speakInstruction("5 feet", rate: 0.4)
            hasAnnounced5Feet = true
        }

        if !hasAnnounced1Foot && remainingFeet <= 1 && remainingFeet > 0.5 {
            speakInstruction("1 foot", rate: 0.4)
            hasAnnounced1Foot = true
        }
    }
    
    private func checkWavepointProgress() {
        guard currentWavepointIndex < wavepointSummaries.count else {
            destinationReached()
            return
        }
        
        let currentWavepoint = wavepointSummaries[currentWavepointIndex]
        let angleChange = currentAngle - wavepointSummaries[currentWavepointIndex].angle
        
        if abs(angleChange) <= 10 && totalDistance >= currentWavepoint.distance {
            completeWaypoint()
        }
    }
    
    private func handleTurning(_ frame: ARFrame) {
        let angleTurned = abs(currentAngle)
        
        updateAngleLabel()

        if angleTurned >= abs(targetAngle) - 5 && angleTurned <= abs(targetAngle) + 5 {
            if !isInTurnCompletionRange {
                isInTurnCompletionRange = true
                startTurnCompletionTimer()
            }
        } else {
            isInTurnCompletionRange = false
            stopTurnCompletionTimer()
            checkAngleCorrection(angleTurned: angleTurned)
        }
    }
    
    private func getCurrentAngle(_ frame: ARFrame) -> Float {
        let currentForwardVector = simd_float3(
            -frame.camera.transform.columns.2.x,
            -frame.camera.transform.columns.2.y,
            -frame.camera.transform.columns.2.z
        )
        
        if initialForwardVector == nil {
            initialForwardVector = currentForwardVector
            print("Warning: initialForwardVector was nil. It has been set to the current forward vector.")
            return 0
        }
        
        let angle = atan2(currentForwardVector.x, currentForwardVector.z) - atan2(initialForwardVector!.x, initialForwardVector!.z)
        let angleDegrees = (angle * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        return angleDegrees > 180 ? angleDegrees - 360 : angleDegrees
    }
    
    private func startTurnCompletionTimer() {
        stopTurnCompletionTimer()
        turnCompletionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            self?.completeTurn()
        }
    }

    private func stopTurnCompletionTimer() {
        turnCompletionTimer?.invalidate()
        turnCompletionTimer = nil
    }
    

    private func completeTurn() {
        isMeasuringAngle = false
        isInTurnZone = false
        currentWavepointIndex += 1
        stopTurnCompletionTimer()
        
        if currentWavepointIndex < wavepointSummaries.count {
            prepareForNextWaypoint()
            announceNextWaypoint()
        } else {
            destinationReached()
        }
    }
    
    private func completeWaypoint() {
        turnCompletionStartTime = nil
        currentWavepointIndex += 1
        isInTurnZone = false
        hasTurnBeenAnnounced = false
        lastTurnInstructionTime = nil
        
        if currentWavepointIndex < wavepointSummaries.count {
            prepareForNextWaypoint()
            announceNextWaypoint()
        } else {
            destinationReached()
        }
    }
    
    private func announceNextDistance() {
        if currentWavepointIndex < wavepointSummaries.count {
            let distance = wavepointSummaries[currentWavepointIndex].distance
            currentWavepointDistance = distance
            let distanceInFeet = cmToFeet(distance)
            let nextTurnDirection = wavepointSummaries[currentWavepointIndex].angle >= 0 ? "right" : "left"
            let instruction = "Walk forward \(String(format: "%.1f", distanceInFeet)) feet and turn \(nextTurnDirection)"
            speakInstruction(instruction, rate: 0.4)
            updateInstructionLabel(instruction)
            updateDistanceLabel(distance: distance)
            hasPreparedForTurn = false
            hasAnnouncedTurn = false
            hasAnnounced5Feet = false
            hasAnnounced1Foot = false
            isInTurnZone = false
        } else {
            destinationReached()
        }
    }
    
    private func destinationReached() {
        if !destinationReachedAnnounced {
            let message = "Destination reached"
            speakInstruction(message)
            updateInstructionLabel(message)
            updateDistanceLabel(distance: 0)
            destinationReachedAnnounced = true
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.returnToHomepage()
            }
        }
    }

    
    private func returnToHomepage() {
        if let navigationController = self.navigationController {
            navigationController.popToRootViewController(animated: true)
        }
    }
    
    private func speakInstruction(_ instruction: String, rate: Float = 0.5, volume: Float = 1.0) {
        let utterance = AVSpeechUtterance(string: instruction)
        utterance.rate = rate
        utterance.volume = volume
        DispatchQueue.main.async {
            self.speechSynthesizer.speak(utterance)
        }
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        isSpeaking = false
    }
    
    private func updateInstructionLabel(_ instruction: String) {
        DispatchQueue.main.async {
            self.instructionLabel.text = instruction
        }
    }
    
    private func updateDistanceLabel(distance: Float) {
        DispatchQueue.main.async {
            self.distanceLabel.text = "Distance: \(String(format: "%.2f", distance)) ft"
        }
    }
    
    private func updateOvershootLabel(distance: Float) {
        DispatchQueue.main.async {
            let overshootFeet = self.cmToFeet(distance)
            self.overshootLabel.text = String(format: "%.2f", overshootFeet)
        }
    }
    
    private func checkAngleRequirements() {
        if targetAngle < 0 {
            handleTurn(lowerBound: -95, upperBound: -85)
        } else {
            handleTurn(lowerBound: 85, upperBound: 95)
        }
    }
    
    private func handleTurn(lowerBound: Float, upperBound: Float) {
        if currentAngle >= lowerBound && currentAngle <= upperBound {
            if turnCompletionStartTime == nil {
                turnCompletionStartTime = Date()
            }
            
            if let startTime = turnCompletionStartTime,
               Date().timeIntervalSince(startTime) >= 2 {
                completeWaypoint()
            }
        } else {
            turnCompletionStartTime = nil
            if canGiveInstruction() {
                giveTurnInstruction(lowerBound: lowerBound, upperBound: upperBound)
            }
        }
    }
    
    private func handleRightTurn() {
        if currentAngle <= -85 && currentAngle >= -95 {
            if turnCompletionStartTime == nil {
                turnCompletionStartTime = Date()
            }
            
            if let startTime = turnCompletionStartTime,
               Date().timeIntervalSince(startTime) >= 2 {
                completeWaypoint()
            }
        } else {
            turnCompletionStartTime = nil
            if canGiveInstruction() {
                giveTurnInstruction(lowerBound: -95, upperBound: -85)
            }
        }
    }

    private func handleLeftTurn() {
        if currentAngle >= 85 && currentAngle <= 95 {
            if turnCompletionStartTime == nil {
                turnCompletionStartTime = Date()
            }
            
            if let startTime = turnCompletionStartTime,
               Date().timeIntervalSince(startTime) >= 2 {
                completeWaypoint()
            }
        } else {
            turnCompletionStartTime = nil
            if canGiveInstruction() {
                giveTurnInstruction(lowerBound: 85, upperBound: 95)
            }
        }
    }
    
    private func giveInitialTurnInstruction() {
        if currentWavepointIndex < wavepointSummaries.count {
            let turnDirection = wavepointSummaries[currentWavepointIndex].angle < 0 ? "right" : "left"
            speakInstruction("Turn \(turnDirection)")
            initialTurnInstructionGiven = true
        }
    }
    
    
    private func giveTurnInstruction(lowerBound: Float, upperBound: Float) {
        guard let lastInstruction = lastTurnInstructionTime,
              Date().timeIntervalSince(lastInstruction) >= turnInstructionInterval else {
            return
        }
        
        let turnDirection = targetAngle < 0 ? "right" : "left"
        
        if targetAngle < 0 {
            if currentAngle > upperBound {
                speakInstruction("Turn a bit more right")
            } else if currentAngle < lowerBound {
                speakInstruction("Turn a bit more left")
            }
        } else {
            if currentAngle < lowerBound {
                speakInstruction("Turn a bit more left")
            } else if currentAngle > upperBound {
                speakInstruction("Turn a bit more right")
            }
        }
        
        lastTurnInstructionTime = Date()
    }
    
    private func canGiveInstruction() -> Bool {
        guard let lastInstruction = lastTurnInstructionTime else {
            return true
        }
        return Date().timeIntervalSince(lastInstruction) >= turnInstructionInterval
    }
    
    private func checkAngleCorrection(angleTurned: Float) {
        guard let lastCorrection = lastAngleCorrectionTime,
              Date().timeIntervalSince(lastCorrection) >= 5.0 else {
            return
        }

        let turnDirection = targetAngle < 0 ? "right" : "left"
        let oppositeTurnDirection = targetAngle < 0 ? "left" : "right"

        if angleTurned < 85 {
            speakInstruction("Turn more to the \(turnDirection)", rate: 0.4, volume: 0.5)
        } else if angleTurned > 95 {
            speakInstruction("Turn more to the \(oppositeTurnDirection)", rate: 0.4, volume: 0.5)
        }

        lastAngleCorrectionTime = Date()
    }
    
    private func checkAngleStability() {
        let currentTime = Date()
        let currentAngleRange = (currentAngle - 10)...(currentAngle + 10)
        
        if isInTurnZone && abs(currentAngle - targetAngle) > 10 {
            if let lastRange = lastAngleRange, currentAngleRange.overlaps(lastRange) {
                if let lastAnnouncementTime = lastAngleAnnouncementTime,
                   currentTime.timeIntervalSince(lastAnnouncementTime) >= 3 {
                    announceAngleCorrection()
                    lastAngleAnnouncementTime = currentTime
                }
            } else {
                lastAngleRange = currentAngleRange
                lastAngleAnnouncementTime = currentTime
            }
        } else {
            lastAngleRange = nil
            lastAngleAnnouncementTime = nil
        }
    }
    
    private func announceAngleCorrection() {
        let turnDirection = targetAngle < 0 ? "right" : "left"
        let oppositeTurnDirection = targetAngle < 0 ? "left" : "right"

        if currentAngle < targetAngle {
            speakInstruction("Move a bit more \(turnDirection).")
        } else {
            speakInstruction("Move a bit more \(oppositeTurnDirection).")
        }
    }
    
    private func cmToFeet(_ cm: Float) -> Float {
        return cm / 30.48
    }
}


@available(iOS 15.4, *)
class MainViewController: UIViewController {
    
    private let logoImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = .white
        return imageView
    }()
    
    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = "SIXTH SENSE"
        label.font = UIFont(name: "Avenir-Heavy", size: 36) ?? UIFont.systemFont(ofSize: 36, weight: .bold)
        label.textColor = .white
        label.textAlignment = .center
        return label
    }()
    
    private let subtitleLabel: UILabel = {
        let label = UILabel()
        label.text = "Navigate with confidence"
        label.font = UIFont(name: "Avenir-Medium", size: 18) ?? UIFont.systemFont(ofSize: 18, weight: .medium)
        label.textColor = .white
        label.textAlignment = .center
        return label
    }()
    
    private let startNavigationButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Start Navigation", for: .normal)
        button.titleLabel?.font = UIFont(name: "Avenir-Heavy", size: 20) ?? UIFont.systemFont(ofSize: 20, weight: .bold)
        button.setTitleColor(.black, for: .normal)
        button.backgroundColor = .white
        button.layer.cornerRadius = 25
        return button
    }()
    
    private let exploreSurroundingsButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Start Pathway Support", for: .normal)
        button.titleLabel?.font = UIFont(name: "Avenir-Heavy", size: 20) ?? UIFont.systemFont(ofSize: 20, weight: .bold)
        button.setTitleColor(.black, for: .normal)
        button.backgroundColor = .white
        button.layer.cornerRadius = 25
        return button
    }()
    
    private let footerLabel: UILabel = {
        let label = UILabel()
        label.text = "Empowering independent journeys"
        label.font = UIFont(name: "Avenir-Medium", size: 16) ?? UIFont.systemFont(ofSize: 16, weight: .medium)
        label.textColor = .white
        label.textAlignment = .center
        return label
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        animateButtonsIn()
    }
    
    private func setupUI() {
        view.backgroundColor = UIColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1.0)
        
        setupLogo()
        
        view.addSubview(titleLabel)
        view.addSubview(subtitleLabel)
        view.addSubview(startNavigationButton)
        view.addSubview(exploreSurroundingsButton)
        view.addSubview(footerLabel)
        
        logoImageView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        startNavigationButton.translatesAutoresizingMaskIntoConstraints = false
        exploreSurroundingsButton.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            logoImageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),
            logoImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            logoImageView.widthAnchor.constraint(equalToConstant: 100),
            logoImageView.heightAnchor.constraint(equalToConstant: 100),
            
            titleLabel.topAnchor.constraint(equalTo: logoImageView.bottomAnchor, constant: 20),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            subtitleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            
            startNavigationButton.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 60),
            startNavigationButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            startNavigationButton.widthAnchor.constraint(equalToConstant: 300),
            startNavigationButton.heightAnchor.constraint(equalToConstant: 50),
            
            exploreSurroundingsButton.topAnchor.constraint(equalTo: startNavigationButton.bottomAnchor, constant: 20),
            exploreSurroundingsButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            exploreSurroundingsButton.widthAnchor.constraint(equalToConstant: 300),
            exploreSurroundingsButton.heightAnchor.constraint(equalToConstant: 50),
            
            footerLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            footerLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
        
        setupButtonActions()
    }
    
    private func setupLogo() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100))
        let img = renderer.image { ctx in
            let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
            ctx.cgContext.setFillColor(UIColor.white.cgColor)
            ctx.cgContext.setStrokeColor(UIColor.white.cgColor)
            ctx.cgContext.setLineWidth(2)
            
            ctx.cgContext.move(to: CGPoint(x: 0, y: 50))
            ctx.cgContext.addQuadCurve(to: CGPoint(x: 100, y: 50),
                                       control: CGPoint(x: 50, y: 0))
            ctx.cgContext.addQuadCurve(to: CGPoint(x: 0, y: 50),
                                       control: CGPoint(x: 50, y: 100))
            ctx.cgContext.strokePath()
            
            ctx.cgContext.addEllipse(in: CGRect(x: 35, y: 35, width: 30, height: 30))
            ctx.cgContext.fillPath()
        }
        
        logoImageView.image = img
        view.addSubview(logoImageView)
    }
    
    private func setupButtonActions() {
        startNavigationButton.addTarget(self, action: #selector(startNavigationTapped), for: .touchUpInside)
        exploreSurroundingsButton.addTarget(self, action: #selector(exploreSurroundingsTapped), for: .touchUpInside)
    }
    
    private func animateButtonsIn() {
        let buttons = [startNavigationButton, exploreSurroundingsButton]
        
        buttons.enumerated().forEach { index, button in
            button.transform = CGAffineTransform(translationX: 0, y: 50)
            button.alpha = 0
            
            UIView.animate(withDuration: 0.6, delay: Double(index) * 0.2, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.1, options: .curveEaseInOut) {
                button.transform = .identity
                button.alpha = 1
            }
        }
    }
    
    @objc private func startNavigationTapped() {
        animateButtonTap(startNavigationButton)
        let mappingVC = MappingViewController()
        navigationController?.pushViewController(mappingVC, animated: true)
    }
    
    @objc private func exploreSurroundingsTapped() {
        animateButtonTap(exploreSurroundingsButton)
        let yoloVC = YOLOViewController()
        navigationController?.pushViewController(yoloVC, animated: true)
    }
    
    private func animateButtonTap(_ button: UIButton) {
        UIView.animate(withDuration: 0.1, animations: {
            button.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
        }) { _ in
            UIView.animate(withDuration: 0.1) {
                button.transform = CGAffineTransform.identity
            }
        }
    }
}

@available(iOS 15.4, *)
class MappingViewController: UIViewController, ARSessionDelegate {
    private var arSession: ARSession!
    private var sceneView: ARSCNView!
    
    private var startPosition: simd_float3?
    private var lastPosition: simd_float3?
    private var totalDistance: Float = 0
    private var isAngleWithinRange = true
    
    private var startAngle: Float = 0
    private var currentAngle: Float = 0
    
    private var isTracking = false
    
    private let distanceLabel = UILabel()
    private let angleLabel = UILabel()
    private let logTextView = UITextView()
    
    private var lastRecordedAngle: Float = 0
    private var cumulativeDistance: Float = 0
    
    private var initialForwardVector: simd_float3?
    
    private var wavepoints: [simd_float3] = []
    private var isInWavepoint = false
    
    private var pathways: [[simd_float3]] = []
    private var currentPathway: [simd_float3] = []
    
    private var wavepointStartPosition: simd_float3?
    private var wavepointStartAngle: Float = 0
    private var wavepointDistance: Float = 0
    
    private var wavepointCount: Int = 0
    private var wavepointSummaries: [WavepointSummary] = []

    private var dataManager = DataManager.shared
    
    private var currentWavepointStartPosition: simd_float3?
    private var currentWavepointDistance: Float = 0
    private var remainingDistance: Float = 0
    private var currentWavepointIndex: Int = 0
    private var hasCrossedDistanceThreshold: Bool = false
    private var initialTurnInstructionGiven: Bool = false
    
    
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Mapping"
        setupARSessionForMapping()
        setupMappingUI()
    }
    
    private func checkAngleForMapping() {
        guard currentWavepointIndex < wavepointSummaries.count else {
            speakInstructionForMapping("All waypoints completed. Navigation finished.")
            return
        }

        let targetAngle = wavepointSummaries[currentWavepointIndex].angle
        let angleDifference = currentAngle - targetAngle
        
        if abs(angleDifference) <= 5 {
            completeWaypointInMapping()
        } else if angleDifference < 0 {
            speakInstructionForMapping("Turn more to the right")
        } else {
            speakInstructionForMapping("Turn more to the left")
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        arSession.run(ARWorldTrackingConfiguration())
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        arSession.pause()
    }
    
    private func setupARSessionForMapping() {
        arSession = ARSession()
        arSession.delegate = self
        
        sceneView = ARSCNView(frame: view.bounds)
        sceneView.session = arSession
        view.addSubview(sceneView)
    }
    
    private func setupMappingUI() {
        let startTrackingButton = UIButton(type: .system)
        startTrackingButton.setTitle("Start Tracking", for: .normal)
        startTrackingButton.addTarget(self, action: #selector(beginMappingTracking), for: .touchUpInside)
        startTrackingButton.frame = CGRect(x: 20, y: 100, width: 150, height: 50)
        view.addSubview(startTrackingButton)
        
        let endTrackingButton = UIButton(type: .system)
        endTrackingButton.setTitle("End Tracking", for: .normal)
        endTrackingButton.addTarget(self, action: #selector(finishMappingTracking), for: .touchUpInside)
        endTrackingButton.frame = CGRect(x: view.bounds.width - 170, y: 100, width: 150, height: 50)
        view.addSubview(endTrackingButton)
        
        let startWavepointButton = UIButton(type: .system)
        startWavepointButton.setTitle("Start Wavepoint", for: .normal)
        startWavepointButton.addTarget(self, action: #selector(initiateMappingWavepoint), for: .touchUpInside)
        startWavepointButton.frame = CGRect(x: 20, y: 160, width: 150, height: 50)
        view.addSubview(startWavepointButton)
        
        let endWavepointButton = UIButton(type: .system)
        endWavepointButton.setTitle("End Wavepoint", for: .normal)
        endWavepointButton.addTarget(self, action: #selector(terminateMappingWavepoint), for: .touchUpInside)
        endWavepointButton.frame = CGRect(x: view.bounds.width - 170, y: 160, width: 150, height: 50)
        view.addSubview(endWavepointButton)
        
        let saveDataButton = UIButton(type: .system)
        saveDataButton.setTitle("Save Data", for: .normal)
        saveDataButton.addTarget(self, action: #selector(storeMappingData), for: .touchUpInside)
        saveDataButton.frame = CGRect(x: 20, y: 220, width: 150, height: 50)
        view.addSubview(saveDataButton)

        let viewSavedDataButton = UIButton(type: .system)
        viewSavedDataButton.setTitle("View Saved Data", for: .normal)
        viewSavedDataButton.addTarget(self, action: #selector(displaySavedMappingData), for: .touchUpInside)
        viewSavedDataButton.frame = CGRect(x: view.bounds.width - 170, y: 220, width: 150, height: 50)
        view.addSubview(viewSavedDataButton)
        
        let resetButton = UIButton(type: .system)
        resetButton.setTitle("Reset", for: .normal)
        resetButton.addTarget(self, action: #selector(resetMappingTracking), for: .touchUpInside)
        resetButton.frame = CGRect(x: (view.bounds.width - 150) / 2, y: 280, width: 150, height: 50)
        view.addSubview(resetButton)
        
        distanceLabel.frame = CGRect(x: 20, y: 290, width: view.bounds.width - 40, height: 30)
        distanceLabel.textAlignment = .center
        distanceLabel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        distanceLabel.textColor = .white
        distanceLabel.layer.cornerRadius = 5
        distanceLabel.clipsToBounds = true
        view.addSubview(distanceLabel)
        
        angleLabel.frame = CGRect(x: 20, y: 330, width: view.bounds.width - 40, height: 30)
        angleLabel.textAlignment = .center
        angleLabel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        angleLabel.textColor = .white
        angleLabel.layer.cornerRadius = 5
        angleLabel.clipsToBounds = true
        view.addSubview(angleLabel)
        
        logTextView.frame = CGRect(x: 20, y: 370, width: view.bounds.width - 40, height: view.bounds.height - 390)
        logTextView.isEditable = false
        logTextView.font = UIFont.systemFont(ofSize: 14)
        logTextView.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        logTextView.textColor = .white
        logTextView.layer.cornerRadius = 10
        logTextView.clipsToBounds = true
        view.addSubview(logTextView)
    }

    @objc private func beginMappingTracking() {
        guard !isTracking else { return }
        isTracking = true
        startPosition = nil
        lastPosition = nil
        totalDistance = 0
        currentAngle = 0
        cumulativeDistance = 0
        lastRecordedAngle = 0
        initialForwardVector = nil
        wavepoints.removeAll()
        pathways.removeAll()
        currentPathway.removeAll()
        isInWavepoint = false
        wavepointCount = 0
        wavepointSummaries.removeAll()
        logForMapping("Tracking started")
    }
    
    @objc private func finishMappingTracking() {
        guard isTracking else { return }
        isTracking = false
        if !currentPathway.isEmpty {
            pathways.append(currentPathway)
            currentPathway.removeAll()
        }
        logForMapping("Tracking ended")
        logWavepointSummaryForMapping()
        logPathwaySummaryForMapping()
    }

    @objc private func initiateMappingWavepoint() {
        guard isTracking, !isInWavepoint else { return }
        isInWavepoint = true
        wavepointCount += 1
        if let currentPosition = lastPosition {
            wavepoints.append(currentPosition)
            currentPathway.append(currentPosition)
            wavepointStartPosition = currentPosition
            wavepointStartAngle = currentAngle
            wavepointDistance = 0
            totalDistance = 0
            cumulativeDistance = 0
            currentAngle = 0
            initialForwardVector = simd_normalize(simd_float3(
                -sceneView.session.currentFrame!.camera.transform.columns.2.x,
                -sceneView.session.currentFrame!.camera.transform.columns.2.y,
                -sceneView.session.currentFrame!.camera.transform.columns.2.z
            ))
            logForMapping("Wavepoint \(wavepointCount) started")
            logForMapping("Distance and angle reset to 0")
            updateMappingUI()
        }
    }

    @objc private func terminateMappingWavepoint() {
        guard isTracking, isInWavepoint else { return }
        isInWavepoint = false
        if let currentPosition = lastPosition {
            wavepoints.append(currentPosition)
            currentPathway.append(currentPosition)
            
            let wavepointEndAngle = currentAngle
            let angleChange = wavepointEndAngle - wavepointStartAngle
            
            let turnDirection = angleChange < 0 ? "right" : "left"
            
            logForMapping("Wavepoint \(wavepointCount) ended")
            logForMapping("  Distance traveled: \(String(format: "%.2f", totalDistance)) cm")
            logForMapping("  Angle moved: \(String(format: "%.2f", abs(angleChange)))° \(turnDirection)")
            
            let summary = WavepointSummary(number: wavepointCount, distance: totalDistance, angle: angleChange)
            wavepointSummaries.append(summary)
        }
    }
    
    private func speakInstructionForMapping(_ instruction: String) {
        print("Instruction: \(instruction)")
    }
    
    
    private func completeWaypointInMapping() {
        currentWavepointIndex += 1
        hasCrossedDistanceThreshold = false
        initialTurnInstructionGiven = false
        currentWavepointStartPosition = nil
        currentWavepointDistance = 0
        
        if currentWavepointIndex < wavepointSummaries.count {
            speakInstructionForMapping("Waypoint completed. Move to the next waypoint.")
        } else {
            speakInstructionForMapping("All waypoints completed. Navigation finished.")
        }
    }
    
    @objc private func resetMappingTracking() {
        isTracking = false
        startPosition = nil
        lastPosition = nil
        totalDistance = 0
        startAngle = 0
        currentAngle = 0
        cumulativeDistance = 0
        lastRecordedAngle = 0
        initialForwardVector = nil
        wavepoints.removeAll()
        pathways.removeAll()
        currentPathway.removeAll()
        isInWavepoint = false
        distanceLabel.text = "Distance: 0.00 cm"
        angleLabel.text = "Angle: 0.00°"
        logTextView.text = ""
        logForMapping("Tracking reset")
    }
    
    @objc private func storeMappingData() {
        let alert = UIAlertController(title: "Save Data", message: "Enter a label for this location", preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "Location Label"
        }
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            guard let label = alert.textFields?.first?.text, !label.isEmpty else {
                self?.logForMapping("Error: Location label is required")
                return
            }
            self?.dataManager.saveData(label: label, wavepointSummaries: self?.wavepointSummaries ?? [])
            self?.logForMapping("Data saved for location: \(label)")
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    @objc private func displaySavedMappingData() {
        let savedDataVC = SavedDataViewController()
        navigationController?.pushViewController(savedDataVC, animated: true)
    }
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isTracking else { return }
        
        let currentPosition = simd_float3(
            frame.camera.transform.columns.3.x,
            frame.camera.transform.columns.3.y,
            frame.camera.transform.columns.3.z
        )
        
        let currentForwardVector = simd_float3(
            -frame.camera.transform.columns.2.x,
            -frame.camera.transform.columns.2.y,
            -frame.camera.transform.columns.2.z
        )
        
        if startPosition == nil {
            startPosition = currentPosition
            lastPosition = currentPosition
            initialForwardVector = currentForwardVector
            return
        }
        
        let angle = atan2(currentForwardVector.x, currentForwardVector.z) - atan2(initialForwardVector!.x, initialForwardVector!.z)
        let angleDegrees = (angle * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        currentAngle = angleDegrees > 180 ? angleDegrees - 360 : angleDegrees
        
        isAngleWithinRange = abs(currentAngle) <= 15
        
        if abs(currentAngle - lastRecordedAngle) > 75 {
            lastRecordedAngle = currentAngle
            logForMapping("Angle shift: \(String(format: "%.2f", currentAngle))°")
        }
        
        let movement = currentPosition - lastPosition!
        let forwardMovement = simd_dot(movement, initialForwardVector!)
        
        if forwardMovement > 0 && isInWavepoint && isAngleWithinRange {
            let forwardMovementCm = forwardMovement * 100
            cumulativeDistance += forwardMovementCm
            
            totalDistance += forwardMovementCm
            
            if cumulativeDistance > 5 {
                logForMapping("Moved forward: \(String(format: "%.2f", totalDistance)) cm")
                cumulativeDistance = 0
            }
        }
        
        lastPosition = currentPosition
        
        updateMappingUI()
        updateRemainingDistanceInMapping()
        checkTurnInstructionsForMapping()
        
        
    }
    
    private func updateRemainingDistanceInMapping() {
        guard let startPos = currentWavepointStartPosition else { return }
        
        let currentPosition = simd_float3(
            sceneView.session.currentFrame!.camera.transform.columns.3.x,
            sceneView.session.currentFrame!.camera.transform.columns.3.y,
            sceneView.session.currentFrame!.camera.transform.columns.3.z
        )
        
        let movement = currentPosition - startPos
        let forwardMovement = simd_length(movement)
        currentWavepointDistance = forwardMovement * 100
        
        if currentWavepointIndex < wavepointSummaries.count {
            remainingDistance = max(0, wavepointSummaries[currentWavepointIndex].distance - currentWavepointDistance)
        } else {
            remainingDistance = 0
        }
        
        updateDistanceLabelForMapping(distance: remainingDistance)
    }
    
    private func updateDistanceLabelForMapping(distance: Float) {
        DispatchQueue.main.async {
            self.distanceLabel.text = "Distance: \(String(format: "%.2f", distance)) cm"
        }
    }
    
    private func giveInitialTurnInstructionForMapping() {
        if currentWavepointIndex < wavepointSummaries.count {
            let turnDirection = wavepointSummaries[currentWavepointIndex].angle < 0 ? "right" : "left"
            speakInstructionForMapping("Turn \(turnDirection)")
            initialTurnInstructionGiven = true
        }
    }

    private func checkTurnInstructionsForMapping() {
        if remainingDistance <= 25 && !hasCrossedDistanceThreshold {
            hasCrossedDistanceThreshold = true
            giveInitialTurnInstructionForMapping()
        }
        
        if hasCrossedDistanceThreshold && initialTurnInstructionGiven {
            checkAngleForMapping()
        }
    }
    
    private func updateMappingUI() {
        distanceLabel.text = "Distance: \(String(format: "%.2f", totalDistance)) cm"
        angleLabel.text = "Angle: \(String(format: "%.2f", currentAngle))°"
    }
    
    private func logForMapping(_ message: String) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss"
        let timestamp = dateFormatter.string(from: Date())
        let logMessage = "[\(timestamp)] \(message)\n"
        logTextView.text = logTextView.text + logMessage
        
        let range = NSMakeRange(logTextView.text.count - 1, 1)
        logTextView.scrollRangeToVisible(range)
    }
    
    private func logWavepointSummaryForMapping() {
        logForMapping("Wavepoint Summary:")
        for summary in wavepointSummaries {
            logForMapping("Wavepoint \(summary.number):")
            logForMapping("  Distance: \(String(format: "%.2f", summary.distance)) cm")
            logForMapping("  Angle: \(String(format: "%.2f", summary.angle))°")
        }
        logForMapping("")
    }
    
    private func logPathwaySummaryForMapping() {
        guard !pathways.isEmpty else {
            logForMapping("No pathways recorded")
            return
        }
        
        for (index, pathway) in pathways.enumerated() {
            logForMapping("Pathway \(index + 1):")
            let wavepointPairs = stride(from: 0, to: pathway.count - 1, by: 2).map {
                (pathway[$0], pathway[$0 + 1])
            }
            
            var pathwayDistance: Float = 0
            
            for (pairIndex, (start, end)) in wavepointPairs.enumerated() {
                let distance = simd_distance(start, end)
                pathwayDistance += distance
                logForMapping("  Wavepoint \(pairIndex + 1): \(String(format: "%.2f", distance * 100)) cm")
            }
            
            logForMapping("  Pathway distance: \(String(format: "%.2f", pathwayDistance * 100)) cm")
            
            if pathway.count >= 2 {
                let startVector = simd_normalize(pathway[1] - pathway[0])
                let endVector = simd_normalize(pathway.last! - pathway[pathway.count - 2])
                let dotProduct = simd_dot(startVector, endVector)
                let angle = acos(dotProduct) * (180 / .pi)
                
                var categorizedAngle: Float
                var direction: String
                
                if angle >= 80 && angle <= 100 {
                    categorizedAngle = 90
                    direction = "straight"
                } else {
                    categorizedAngle = abs(angle)
                    direction = angle < 0 ? "right" : "left"
                }
                
                if direction == "straight" {
                    logForMapping("  Final angle: 90° (straight)")
                } else {
                    logForMapping("  Final angle: \(String(format: "%.2f", categorizedAngle))° \(direction)")
                }
            }
            
            logForMapping("")
        }
        
        let totalPathwayDistance = pathways.flatMap { $0 }.chunked(into: 2).reduce(0) { $0 + simd_distance($1[0], $1[1]) }
        logForMapping("Total distance across all pathways: \(String(format: "%.2f", totalPathwayDistance * 100)) cm")
    }
}


struct Detection {
    let box: CGRect
    let confidence: Double
    let label: String
    let distance: Double
}

@available(iOS 15.4, *)
class YOLOViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate, AVSpeechSynthesizerDelegate {
    private var captureSession = AVCaptureSession()
    private var previewView = UIImageView()
    private var videoOutput: AVCaptureVideoDataOutput!
    private var frameCounter = 0
    private let frameInterval = 2
    private var videoSize = CGSize.zero
    private let ciContext = CIContext()
    private var currentPixelBuffer: CVPixelBuffer?

    private let focalLength: Double = 4.25
    private let sensorWidth: Double = 4.80
    private let sensorHeight: Double = 3.60
    
    
    
    private let maxAnnouncementDistance: Double = 1.0
    private let announcementInterval: TimeInterval = 1.5
    private var lastAnnouncementTimes: [String: Date] = [:]
    private let announcementCooldown: TimeInterval = 60.0
    
    private var flashlightButton: UIButton!
    private var isFlashlightOn = false

    private let referenceSizes: [String: (width: Double, height: Double)] = [
        "person": (0.5, 1.7),
        "bicycle": (1.5, 1.0),
        "car": (1.8, 1.5),
        "motorcycle": (2.0, 1.2),
        "truck": (2.5, 2.5),
        "bus": (2.5, 3.0),
        "dog": (0.4, 0.6),
        "cat": (0.3, 0.35),
        "chair": (0.5, 0.8),
        "cell phone": (0.0715, 0.1475),
        "bag": (0.4, 0.5),
        "tv": (1.2, 0.7),
        "laptop": (0.35, 0.25),
        "fork": (0.02, 0.15),
        "spoon": (0.02, 0.15),
        "mouse": (0.07, 0.12),
        "keyboard": (0.45, 0.15),
        "bottle": (0.08, 0.25),
        "cup": (0.08, 0.10),
        "remote": (0.05, 0.15),
        "book": (0.15, 0.22),
    ]

    private let colors: [UIColor] = [
        .red, .green, .blue, .yellow, .cyan, .magenta, .orange, .purple, .brown, .gray
    ]

    private let speechSynthesizer = AVSpeechSynthesizer()
    private var lastSpokenTime: [String: Date] = [:]
    private let speechCooldown: TimeInterval = 3.0
    private var announcementQueue: [(label: String, distance: Double)] = []
    private var isSpeaking = false

    private lazy var yoloRequest: VNCoreMLRequest = {
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndGPU
            guard let model = try? VNCoreMLModel(for: yolov8n().model) else {
                fatalError("Failed to load YOLO model")
            }
            let request = VNCoreMLRequest(model: model) { [weak self] request, error in
                self?.processYOLOResults(request: request, error: error)
            }
            request.imageCropAndScaleOption = .scaleFill
            return request
        } catch {
            fatalError("Failed to create YOLO request: \(error)")
        }
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "YOLO Object Detection"
        setupVideo()
        setupOrientationObserver()
        setupAudioSession()
        setupFlashlightButton()
        speechSynthesizer.delegate = self

        let testUtterance = AVSpeechUtterance(string: "Object detection initialized")
        testUtterance.rate = 0.5
        testUtterance.volume = 1.0
        DispatchQueue.main.async {
            self.speechSynthesizer.speak(testUtterance)
        }
    }
    
    @objc private func toggleFlashlight() {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else {
            print("Flashlight not available on this device")
            return
        }

        do {
            try device.lockForConfiguration()
            
            if device.torchMode == .on {
                device.torchMode = .off
                isFlashlightOn = false
                flashlightButton.setImage(UIImage(systemName: "flashlight.off.fill"), for: .normal)
            } else {
                try device.setTorchModeOn(level: 1.0)
                isFlashlightOn = true
                flashlightButton.setImage(UIImage(systemName: "flashlight.on.fill"), for: .normal)
            }
            
            device.unlockForConfiguration()
        } catch {
            print("Error toggling flashlight: \(error)")
        }
    }
    
    private func setupFlashlightButton() {
        flashlightButton = UIButton(type: .system)
        flashlightButton.setImage(UIImage(systemName: "flashlight.off.fill"), for: .normal)
        flashlightButton.tintColor = .white
        flashlightButton.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        flashlightButton.layer.cornerRadius = 25
        flashlightButton.addTarget(self, action: #selector(toggleFlashlight), for: .touchUpInside)
        
        view.addSubview(flashlightButton)
        flashlightButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            flashlightButton.leftAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leftAnchor, constant: 20),
            flashlightButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            flashlightButton.widthAnchor.constraint(equalToConstant: 50),
            flashlightButton.heightAnchor.constraint(equalToConstant: 50)
        ])
    }


    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory("AVAudioSessionCategoryPlayback")
            try audioSession.setMode("AVAudioSessionModeDefault")
            try audioSession.setActive(true)
        } catch {
            print("Failed to set audio session category: \(error)")
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession.startRunning()
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureSession.stopRunning()
    }

    private func setupVideo() {
        previewView.frame = view.bounds
        previewView.contentMode = .scaleAspectFill
        view.addSubview(previewView)

        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1280x720

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            fatalError("No wide angle camera available")
        }

        do {
            let deviceInput = try AVCaptureDeviceInput(device: device)
            if captureSession.canAddInput(deviceInput) {
                captureSession.addInput(deviceInput)
            }
        } catch {
            fatalError("Could not create video input: \(error)")
        }

        videoOutput = AVCaptureVideoDataOutput()
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "VideoQueue", qos: .userInteractive))
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        if let connection = videoOutput.connection(with: .video) {
            connection.videoOrientation = .portrait
        }

        captureSession.commitConfiguration()
    }

    private func setupOrientationObserver() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(orientationChanged),
                                               name: NSNotification.Name.UIDeviceOrientationDidChange,
                                               object: nil)
    }

    @objc private func orientationChanged() {
        guard let connection = videoOutput.connection(with: .video),
              connection.isVideoOrientationSupported else { return }

        let currentOrientation = UIDevice.current.orientation
        let videoOrientation: AVCaptureVideoOrientation

        switch currentOrientation {
        case .portrait: videoOrientation = .portrait
        case .portraitUpsideDown: videoOrientation = .portraitUpsideDown
        case .landscapeLeft: videoOrientation = .landscapeRight
        case .landscapeRight: videoOrientation = .landscapeLeft
        default: videoOrientation = .portrait
        }

        connection.videoOrientation = videoOrientation
        DispatchQueue.main.async { [weak self] in
            self?.adjustPreviewForCurrentOrientation()
        }
    }

    private func adjustPreviewForCurrentOrientation() {
        let orientation = UIDevice.current.orientation
        var transform: CGAffineTransform = .identity

        switch orientation {
        case .landscapeLeft:
            transform = CGAffineTransform(rotationAngle: CGFloat.pi / 2)
        case .landscapeRight:
            transform = CGAffineTransform(rotationAngle: -CGFloat.pi / 2)
        case .portraitUpsideDown:
            transform = CGAffineTransform(rotationAngle: CGFloat.pi)
        default:
            break
        }

        UIView.animate(withDuration: 0.3) {
            self.previewView.transform = transform
            self.previewView.frame = self.view.bounds
        }
    }

    private func processYOLOResults(request: VNRequest, error: Error?) {
        print("Processing YOLO results")
        guard let results = request.results as? [VNRecognizedObjectObservation] else {
            print("No results from YOLO")
            return
        }

        let filteredResults = results.filter { $0.confidence > 0.5 }
        let nmsResults = nonMaxSuppression(detections: filteredResults)

        let detections = nmsResults.compactMap { result -> Detection? in
            guard let topLabelObservation = result.labels.first else { return nil }

            let label = topLabelObservation.identifier
            let confidence = result.confidence
            let box = result.boundingBox

            guard let referenceSize = referenceSizes[label] else { return nil }
            let distance = estimateDistance(for: referenceSize, boundingBox: box)

            let frameWidth = CGFloat(videoSize.width)
            let horizontalAngle = calculateHorizontalAngle(for: box, frameWidth: frameWidth)
            
            print("\(label) detected at an angle of \(horizontalAngle) degrees")
            
            return Detection(box: box, confidence: Double(confidence), label: label, distance: distance)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let pixelBuffer = self.currentPixelBuffer else { return }
            let image = self.drawDetectionsOnImage(detections, pixelBuffer: pixelBuffer)
            self.previewView.image = image
            self.announceNearbyObjects(detections)
        }
    }

    private func calculateHorizontalAngle(for boundingBox: CGRect, frameWidth: CGFloat) -> Double {
        let horizontalFOV = 2 * atan(sensorWidth / (2 * focalLength))
        let horizontalFOVDegrees = horizontalFOV * (180.0 / Double.pi)
        let midX = boundingBox.midX
        let relativePosition = midX - 0.5
        let angle = relativePosition * horizontalFOVDegrees
        return angle
    }

    private func drawDetectionsOnImage(_ detections: [Detection], pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        let size = ciImage.extent.size

        UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
        guard let context = UIGraphicsGetCurrentContext() else { return nil }

        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1.0, y: -1.0)
        context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        context.scaleBy(x: 1.0, y: -1.0)
        context.translateBy(x: 0, y: -size.height)

        for (index, detection) in detections.enumerated() {
            let color = colors[index % colors.count]
            let box = CGRect(x: detection.box.minX * size.width,
                             y: (1 - detection.box.maxY) * size.height,
                             width: detection.box.width * size.width,
                             height: detection.box.height * size.height)

            context.setStrokeColor(color.cgColor)
            context.setLineWidth(3)
            context.stroke(box)

            let distanceString = String(format: "%.2f", detection.distance)
            let angle = calculateHorizontalAngle(for: detection.box, frameWidth: size.width)

            let direction: String
            if angle < -10 {
                direction = "Left"
            } else if angle > 10 {
                direction = "Right"
            } else {
                direction = "Center"
            }

            let text = "\(detection.label): \(Int(detection.confidence * 100))%\nDist: \(distanceString)m\nAngle: \(String(format: "%.2f", angle))° (\(direction))"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 14),
                .foregroundColor: UIColor.white
            ]

            let textSize = text.size(withAttributes: attributes)
            let textRect = CGRect(x: box.minX,
                                  y: box.minY - textSize.height - 5,
                                  width: textSize.width,
                                  height: textSize.height)

            context.setFillColor(UIColor.black.withAlphaComponent(0.6).cgColor)
            context.fill(textRect)

            text.draw(in: textRect, withAttributes: attributes)
        }

        let resultImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return resultImage
    }

    private func announceNearbyObjects(_ detections: [Detection]) {
        let now = Date()
        let nearbyObjects = detections.filter { $0.distance <= maxAnnouncementDistance }
            .sorted { $0.distance < $1.distance }

        for object in nearbyObjects {
            if let lastAnnouncement = lastAnnouncementTimes[object.label],
               now.timeIntervalSince(lastAnnouncement) < announcementCooldown {
                continue
            }

            let distanceString = String(format: "%.1f", object.distance)
            let angle = calculateHorizontalAngle(for: object.box, frameWidth: CGFloat(videoSize.width))
            let direction: String
            if angle < -10 {
                direction = "left"
            } else if angle > 10 {
                direction = "right"
            } else {
                direction = "ahead"
            }

            let announcement = "\(object.label), \(distanceString) meters, \(direction)"
            announcementQueue.append((label: announcement, distance: object.distance))
            lastAnnouncementTimes[object.label] = now

            break
        }

        if !isSpeaking {
            speakNextObject()
        }
    }

    private func nonMaxSuppression(detections: [VNRecognizedObjectObservation], overlapThreshold: CGFloat = 0.5) -> [VNRecognizedObjectObservation] {
        let sortedDetections = detections.sorted { $0.confidence > $1.confidence }
        var selectedDetections: [VNRecognizedObjectObservation] = []

        for detection in sortedDetections {
            var shouldSelect = true

            for selectedDetection in selectedDetections {
                let overlap = intersection(boxA: detection.boundingBox, boxB: selectedDetection.boundingBox)
                let unionArea = detection.boundingBox.width * detection.boundingBox.height +
                                selectedDetection.boundingBox.width * selectedDetection.boundingBox.height -
                                overlap

                let iou = overlap / unionArea

                if iou > overlapThreshold {
                    shouldSelect = false
                    break
                }
            }

            if shouldSelect {
                selectedDetections.append(detection)
            }
        }

        return selectedDetections
    }

    private func intersection(boxA: CGRect, boxB: CGRect) -> CGFloat {
        let maxX = min(boxA.maxX, boxB.maxX)
        let maxY = min(boxA.maxY, boxB.maxY)
        let minX = max(boxA.minX, boxB.minX)
        let minY = max(boxA.minY, boxB.minY)

        let width = max(0, maxX - minX)
        let height = max(0, maxY - minY)

        return width * height
    }

    private func estimateDistance(for referenceSize: (width: Double, height: Double), boundingBox: CGRect) -> Double {
        let boxWidth = Double(boundingBox.width)
        let boxHeight = Double(boundingBox.height)
        
        let boxArea = boxWidth * boxHeight
        let realArea = referenceSize.width * referenceSize.height
        let sensorArea = sensorWidth * sensorHeight
        
        let distanceByWidth = (referenceSize.width * focalLength) / (boxWidth * sensorWidth)
        let distanceByHeight = (referenceSize.height * focalLength) / (boxHeight * sensorHeight)
        let distanceByArea = (realArea * focalLength * focalLength) / (boxArea * sensorArea)
        
        let estimatedDistance = (distanceByWidth + distanceByHeight + distanceByArea) / 3.0
        
        return applyKalmanFilter(to: estimatedDistance)
    }

    private var lastEstimate: Double = 0
    private var errorEstimate: Double = 1
    private let q: Double = 0.1
    private let r: Double = 0.1

    private func applyKalmanFilter(to measurement: Double) -> Double {
        let prediction = lastEstimate
        errorEstimate += q

        let kalmanGain = errorEstimate / (errorEstimate + r)
        let estimate = prediction + kalmanGain * (measurement - prediction)
        errorEstimate = (1 - kalmanGain) * errorEstimate

        lastEstimate = estimate
        return estimate
    }

    private func speakNextObject() {
        guard !announcementQueue.isEmpty else {
            isSpeaking = false
            return
        }
        isSpeaking = true

        let nextObject = announcementQueue.removeFirst()
        let utterance = AVSpeechUtterance(string: nextObject.label)
        utterance.rate = 0.4
        utterance.volume = 1.0
        print("Speaking: \(utterance.speechString)")
        DispatchQueue.main.async {
            self.speechSynthesizer.speak(utterance)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.speakNextObject()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameCounter += 1
        guard frameCounter == frameInterval else { return }
        frameCounter = 0

        if videoSize == .zero {
            if let description = CMSampleBufferGetFormatDescription(sampleBuffer) {
                let dimensions = CMVideoFormatDescriptionGetDimensions(description)
                videoSize = CGSize(width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))
                print("Video size set to: \(videoSize)")
            }
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        currentPixelBuffer = pixelBuffer
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([yoloRequest])
        } catch {
            print("Error performing YOLO request: \(error)")
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

@available(iOS 15.4, *)
@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        let mainViewController = MainViewController()
        let navigationController = UINavigationController(rootViewController: mainViewController)
        window?.rootViewController = navigationController
        window?.makeKeyAndVisible()
        return true
    }
}
