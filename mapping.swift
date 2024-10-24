// Mapping.swift

import SwiftUI
import CoreLocation
import ARKit
import Vision
import AVFoundation

// MARK: - Data Structures

struct Waypoint: Codable, Identifiable {
    let id: UUID
    let name: String
    let position: SIMD3<Float>
}

struct Path: Codable, Identifiable {
    let id: UUID
    let from: UUID
    let to: UUID
    let instructions: String
}

struct MapData: Codable {
    let waypoints: [Waypoint]
    let paths: [Path]
}

// MARK: - Indoor Mapping Manager

@available(iOS 15.2,*)
class IndoorMappingManager: NSObject, ObservableObject {
    @Published var waypoints: [Waypoint] = []
    @Published var paths: [Path] = []
    @Published var currentPosition: SIMD3<Float>?
    @Published var isMapping: Bool = false
    
    private let arSession = ARSession()
    private let locationManager = CLLocationManager()
    private let speechSynthesizer = AVSpeechSynthesizer()
    
    override init() {
        super.init()
        setupARSession()
        setupLocationManager()
    }
    
    private func setupARSession() {
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        arSession.delegate = self
        arSession.run(configuration)
    }
    
    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingHeading()
    }
    
    func startMapping() {
        isMapping = true
    }
    
    func stopMapping() {
        isMapping = false
    }
    
    func addWaypoint(name: String) {
        guard let position = currentPosition else { return }
        let waypoint = Waypoint(id: UUID(), name: name, position: position)
        waypoints.append(waypoint)
    }
    
    func addPath(from: UUID, to: UUID, instructions: String) {
        let path = Path(id: UUID(), from: from, to: to, instructions: instructions)
        paths.append(path)
    }
    
    func navigate(from startId: UUID, to endId: UUID) {
        guard let path = findPath(from: startId, to: endId) else {
            speakInstruction("No path found")
            return
        }
        
        for instruction in path {
            speakInstruction(instruction)
        }
    }
    
    private func findPath(from startId: UUID, to endId: UUID) -> [String]? {
        // Simple pathfinding - can be improved with more advanced algorithms
        var instructions: [String] = []
        var currentId = startId
        
        while currentId != endId {
            guard let path = paths.first(where: { $0.from == currentId && $0.to == endId }) ??
                    paths.first(where: { $0.from == currentId }) else {
                return nil
            }
            
            instructions.append(path.instructions)
            currentId = path.to
        }
        
        instructions.append("You have reached your destination.")
        return instructions
    }
    
    private func speakInstruction(_ instruction: String) {
        let utterance = AVSpeechUtterance(string: instruction)
        speechSynthesizer.speak(utterance)
    }
    
    func saveMap() {
        let data = MapData(waypoints: waypoints, paths: paths)
        if let encoded = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(encoded, forKey: "IndoorMap")
        }
    }
    
    func loadMap() {
        if let data = UserDefaults.standard.data(forKey: "IndoorMap"),
           let mapData = try? JSONDecoder().decode(MapData.self, from: data) {
            waypoints = mapData.waypoints
            paths = mapData.paths
        }
    }
}

// MARK: - AR Session Delegate
@available(iOS 15.2,*)

extension IndoorMappingManager: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        currentPosition = SIMD3<Float>(frame.camera.transform.columns.3.x,
                                       frame.camera.transform.columns.3.y,
                                       frame.camera.transform.columns.3.z)

    }
}

// MARK: - Location Manager Delegate
@available(iOS 15.2,*)

extension IndoorMappingManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // Use heading information if needed
    }
}

// MARK: - SwiftUI Views

@available(iOS 15.2,*)

struct ContentView: View {
    @StateObject private var mappingManager = IndoorMappingManager()
    @State private var newWaypointName = ""
    @State private var selectedStartWaypoint: UUID?
    @State private var selectedEndWaypoint: UUID?
    @State private var pathInstructions = ""
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Mapping")) {
                    Button(mappingManager.isMapping ? "Stop Mapping" : "Start Mapping") {
                        if mappingManager.isMapping {
                            mappingManager.stopMapping()
                        } else {
                            mappingManager.startMapping()
                        }
                    }
                    
                    if mappingManager.isMapping {
                        HStack {
                            TextField("Waypoint Name", text: $newWaypointName)
                            Button("Add") {
                                mappingManager.addWaypoint(name: newWaypointName)
                                newWaypointName = ""
                            }
                        }
                    }
                }
                
                Section(header: Text("Waypoints")) {
                    ForEach(mappingManager.waypoints) { waypoint in
                        Text(waypoint.name)
                    }
                }
                
                Section(header: Text("Add Path")) {
                    Picker("Start", selection: $selectedStartWaypoint) {
                        ForEach(mappingManager.waypoints) { waypoint in
                            Text(waypoint.name).tag(waypoint.id as UUID?)
                        }
                    }
                    
                    Picker("End", selection: $selectedEndWaypoint) {
                        ForEach(mappingManager.waypoints) { waypoint in
                            Text(waypoint.name).tag(waypoint.id as UUID?)
                        }
                    }
                    
                    TextField("Instructions", text: $pathInstructions)
                    
                    Button("Add Path") {
                        if let start = selectedStartWaypoint, let end = selectedEndWaypoint {
                            mappingManager.addPath(from: start, to: end, instructions: pathInstructions)
                            pathInstructions = ""
                        }
                    }
                }
                
                Section(header: Text("Navigation")) {
                    Button("Start Navigation") {
                        if let start = selectedStartWaypoint, let end = selectedEndWaypoint {
                            mappingManager.navigate(from: start, to: end)
                        }
                    }
                }
            }
            .navigationTitle("Indoor Mapping")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save Map") {
                        mappingManager.saveMap()
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Load Map") {
                        mappingManager.loadMap()
                    }
                }
            }
        }
    }
}

// MARK: - Preview Provider
@available(iOS 15.2,*)

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
