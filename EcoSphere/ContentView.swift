//
//  ContentView.swift
//  EcoSphere
//
//  Created by Manab Kumar Biswas on 08/10/2024.
//

import SwiftUI
import MapKit
import Foundation
import CoreLocation
import AVFoundation

class UserManager {
    static let shared = UserManager()
    private let userIDKey = "EcoSphereUserID"
    
    var userID: String {
        if let existingID = UserDefaults.standard.string(forKey: userIDKey) {
            return existingID
        } else {
            let newID = UUID().uuidString
            UserDefaults.standard.set(newID, forKey: userIDKey)
            return newID
        }
    }
}

class HeatmapAnnotation: MKPointAnnotation {}

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private var locationBatch: [[String: Any]] = []
    private var uploadTimer: Timer?

    @Published var location: CLLocationCoordinate2D? = nil
    @Published var heatmapData: [HeatmapAnnotation] = []
    @Published var environmentalData: [String: Any] = [:]

    var audioRecorder: AudioRecorder

    init(audioRecorder: AudioRecorder) {
        self.audioRecorder = audioRecorder
        super.init()
        self.locationManager.delegate = self
        self.locationManager.desiredAccuracy = kCLLocationAccuracyBest
        checkLocationAuthorization()
    }

    private func checkLocationAuthorization() {
        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    func startUpdatingLocation() {
        print("Starting location updates")
        self.locationManager.startUpdatingLocation()
        startUploadTimer()
    }

    func stopUpdatingLocation() {
        print("Stopping location updates")
        self.locationManager.stopUpdatingLocation()
        uploadTimer?.invalidate()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.first {
            DispatchQueue.main.async {
                self.location = location.coordinate
                self.addLocationToBatch(location: location)
            }
        }
    }

    private func addLocationToBatch(location: CLLocation) {
        let data: [String: Any] = [
            "userID": UserManager.shared.userID,
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "timestamp": Date().timeIntervalSince1970
        ]
        locationBatch.append(data)
        saveLocationDataLocally(data: data)
    }

    private func saveLocationDataLocally(data: [String: Any]) {
        let fileURL = getDocumentsDirectory().appendingPathComponent("locationData.txt")
        let dataString = "UserID: \(data["userID"]!), Latitude: \(data["latitude"]!), Longitude: \(data["longitude"]!), Timestamp: \(data["timestamp"]!)\n"

        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let fileHandle = try FileHandle(forWritingTo: fileURL)
                fileHandle.seekToEndOfFile()
                fileHandle.write(dataString.data(using: .utf8)!)
                fileHandle.closeFile()
            } else {
                try dataString.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        } catch {
            print("Error saving location data: \(error)")
        }
    }

    private func startUploadTimer() {
        uploadTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.uploadLocationBatch()
        }
    }

    private func uploadLocationBatch() {
        guard !locationBatch.isEmpty else { return }

        guard let randomLocation = locationBatch.randomElement() else { return }
        let latitude = randomLocation["latitude"] as! Double
        let longitude = randomLocation["longitude"] as! Double

        fetchEnvironmentalData(latitude: latitude, longitude: longitude) { environmentData in
            var batchWithEnvironment = self.locationBatch
            batchWithEnvironment.append(["environmentData": environmentData])

            let url = URL(string: "https://ecosphere-421ef-default-rtdb.europe-west1.firebasedatabase.app/locationData.json")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let batchData = ["locations": batchWithEnvironment]
            request.httpBody = try? JSONSerialization.data(withJSONObject: batchData, options: [])

            URLSession.shared.dataTask(with: request) { _, _, error in
                if let error = error {
                    print("Failed to upload location batch: \(error)")
                } else {
                    print("Location batch with environmental data uploaded to Firebase")
                    self.locationBatch.removeAll()
                }
            }.resume()
        }
    }

    private func fetchEnvironmentalData(latitude: Double, longitude: Double, completion: @escaping ([String: Any]) -> Void) {
        let weatherAPI = "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)&hourly=temperature_2m,precipitation,cloudcover,windspeed_10m"
        let aqiAPI = "https://api.waqi.info/feed/geo:\(latitude);\(longitude)/?token=9dcc21715b5cc7ae7566d841eadb43275ca41ac1"

        var environmentData: [String: Any] = [:]

        let group = DispatchGroup()
        
        group.enter()
        URLSession.shared.dataTask(with: URL(string: weatherAPI)!) { data, _, error in
            defer { group.leave() }
            if let data = data {
                do {
                    let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
                    let hourlyData = json?["hourly"] as? [String: Any] ?? [:]
                    environmentData["weather"] = hourlyData
                } catch {
                    print("Error decoding weather data: \(error)")
                }
            } else if let error = error {
                print("Error fetching weather data: \(error)")
            }
        }.resume()
        
        group.enter()
        URLSession.shared.dataTask(with: URL(string: aqiAPI)!) { data, _, error in
            defer { group.leave() }
            if let data = data {
                do {
                    let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
                    let aqiData = json?["data"] as? [String: Any]
                    environmentData["aqi"] = aqiData?["aqi"]
                } catch {
                    print("Error decoding AQI data: \(error)")
                }
            } else if let error = error {
                print("Error fetching AQI data: \(error)")
            }
        }.resume()

        group.enter()
        findNearestPark(from: CLLocation(latitude: latitude, longitude: longitude)) { parkData in
            environmentData["nearestGreenSpace"] = parkData
            group.leave()
        }
        
        group.notify(queue: .main) {
            self.audioRecorder.updateSoundIntensityPublic()
            environmentData["soundIntensity"] = self.audioRecorder.soundIntensity
            self.environmentalData = environmentData
            completion(environmentData)
            self.updateHeatmap(with: environmentData, latitude: latitude, longitude: longitude)
        }
    }

    private func findNearestPark(from location: CLLocation, completion: @escaping ([String: Any]) -> Void) {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "Park"
        request.region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 5000, longitudinalMeters: 5000)
        
        let search = MKLocalSearch(request: request)
        search.start { response, error in
            if let error = error {
                print("Error finding parks: \(error)")
                completion(["distance": -1])
            } else if let mapItem = response?.mapItems.first {
                let distance = location.distance(from: mapItem.placemark.location!)
                completion(["name": mapItem.name ?? "Unknown", "distance": distance])
            } else {
                completion(["distance": -1])
            }
        }
    }

    private func updateHeatmap(with environmentData: [String: Any], latitude: Double, longitude: Double) {
        let annotation = HeatmapAnnotation()
        annotation.coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)

        let aqi = environmentData["aqi"] as? Int ?? 0
        let soundIntensity = environmentData["soundIntensity"] as? Float ?? 0.0
        let currentHour = Calendar.current.component(.hour, from: Date())
        var conditions: Float = 0.0
        var greenSpace: Float = 0.0
        
        if let weatherData = environmentData["weather"] as? [String: Any],
           let temperatureArray = weatherData["temperature_2m"] as? [Float] {
            conditions = temperatureArray[currentHour % 24]
        } else {
            conditions = 0.0
        }

        if let greenSpaceData = environmentData["nearestGreenSpace"] as? [String: Any],
           let greenSpaceDistance = greenSpaceData["distance"] as? Float {
            greenSpace = greenSpaceDistance
        } else {
            greenSpace = 0.0
        }
        
        annotation.title = "AQI: \(aqi), Sound: \(String(format: "%.2f", soundIntensity)), Conditions: \(String(format: "%.2f", conditions)), GreenSpace: \(String(format: "%.2f", greenSpace))"

        DispatchQueue.main.async {
            self.heatmapData.append(annotation)
        }
    }

    private func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}

class AudioRecorder: NSObject, ObservableObject {
    private var audioRecorder: AVAudioRecorder?
    private var recordingTimer: Timer?
    private var levelTimer: Timer?

    @Published var isRecording = false
    @Published var soundIntensity: Float = 0.0
    private var audioBatch: [URL] = []

    func startRecording() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, options: [.allowBluetooth, .defaultToSpeaker, .mixWithOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("Failed to set up audio session: \(error.localizedDescription)")
            return
        }

        startRecordingSession()

        recordingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.stopRecordingSession()
            self?.startRecordingSession()
        }

        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateSoundIntensity()
        }
    }

    private func startRecordingSession() {
        let audioFilename = getDocumentsDirectory().appendingPathComponent("\(UUID().uuidString).m4a")

        let settings = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 12000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()
            isRecording = true
            print("Audio recording started")
        } catch {
            print("Failed to start recording: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        recordingTimer?.invalidate()
        levelTimer?.invalidate()
        stopRecordingSession()

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setActive(false)
        } catch {
            print("Failed to deactivate audio session: \(error.localizedDescription)")
        }
    }

    private func stopRecordingSession() {
        if isRecording {
            audioRecorder?.stop()
            isRecording = false
            if let audioURL = audioRecorder?.url {
                saveAudioDataLocally(audioFileURL: audioURL)
            }
        }
    }

    private func updateSoundIntensity() {
        guard let recorder = audioRecorder else { return }
        recorder.updateMeters()

        let decibels = recorder.averagePower(forChannel: 0)
        let intensity = pow(10.0, decibels / 20.0) * 100
        soundIntensity = Float(intensity)
        print("Sound intensity: \(soundIntensity)")
    }
    
    func updateSoundIntensityPublic() {
        guard let recorder = audioRecorder else { return }
        recorder.updateMeters()

        let decibels = recorder.averagePower(forChannel: 0)
        let intensity = pow(10.0, decibels / 20.0) * 100
        soundIntensity = Float(intensity)
        print("Sound intensity updated: \(soundIntensity)")
    }

    private func saveAudioDataLocally(audioFileURL: URL) {
        let localURL = getDocumentsDirectory().appendingPathComponent("Saved_Audio").appendingPathComponent(audioFileURL.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: audioFileURL, to: localURL)
            print("Audio saved locally at \(localURL)")
            audioBatch.append(localURL)
        } catch {
            print("Failed to save audio locally: \(error)")
        }
    }

    private func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}

struct MapView: UIViewRepresentable {
    @Binding var heatmapData: [HeatmapAnnotation]

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.userTrackingMode = .follow
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        mapView.removeOverlays(mapView.overlays)

        for annotation in heatmapData {
            if let overlay = generateHeatmapOverlay(for: annotation) {
                mapView.addOverlay(overlay)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func generateHeatmapOverlay(for annotation: HeatmapAnnotation) -> MKPolygon? {
        let radius: Double = 1000
        let centerCoordinate = annotation.coordinate

        let circlePoints = stride(from: 0.0, to: 360.0, by: 10.0).map { angle -> CLLocationCoordinate2D in
            let radian = angle * Double.pi / 180
            let latitude = centerCoordinate.latitude + (radius / 6378137.0) * cos(radian) * (180 / Double.pi)
            let longitude = centerCoordinate.longitude + (radius / 6378137.0) * sin(radian) * (180 / Double.pi) / cos(centerCoordinate.latitude * Double.pi / 180)
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }

        return MKPolygon(coordinates: circlePoints, count: circlePoints.count)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: MapView

        init(_ parent: MapView) {
            self.parent = parent
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polygon = overlay as? MKPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)

                if let annotation = parent.heatmapData.first(where: { $0.coordinate.latitude == polygon.coordinate.latitude && $0.coordinate.longitude == polygon.coordinate.longitude }) {
                    let aqi = extractValue(from: annotation.title, prefix: "AQI: ")
                    let soundIntensity = extractValue(from: annotation.title, prefix: "Sound: ")

                    let proximityScore = annotation.title?.contains("GreenSpace") == true ? 0.5 : 1.0
                    let temperatureScore = annotation.title?.contains("Conditions") == true ? 1.0 : 0.2

                    let intensity = min(1.0, (Double(aqi) / 500.0) + proximityScore + temperatureScore + (Double(soundIntensity) / 10.0))
                    renderer.fillColor = UIColor(red: CGFloat(intensity), green: CGFloat(1.0 - intensity), blue: 0.0, alpha: 0.5)
                    renderer.strokeColor = .clear
                }

                return renderer
            }
            return MKOverlayRenderer()
        }

        private func extractValue(from string: String?, prefix: String) -> Float {
            guard let string = string else { return 0.0 }
            if let range = string.range(of: prefix) {
                let valueString = string[range.upperBound...].trimmingCharacters(in: .whitespaces)
                return Float(valueString) ?? 0.0
            }
            return 0.0
        }
    }
}

struct MinimalistBar: View {
    @Binding var isExpanded: Bool
    @Binding var greenIndex: Float

    var body: some View {
        VStack {
            Spacer()

            HStack {
                Spacer()

                Button(action: {
                    isExpanded.toggle()
                }) {
                    Text(String(format: "%.2f", greenIndex))
                        .font(.title2)
                        .fontWeight(.bold)
                        .frame(width: 60, height: 60)
                        .background(Circle().fill(Color.green))
                        .foregroundColor(Color.primary)
                        .shadow(radius: 10)
                }
                
                Spacer()
            }
            .padding(.vertical, 10)
            .padding(.horizontal)
            .background(Color.primary)
            .cornerRadius(30)
            .shadow(radius: 10)
        }
        .edgesIgnoringSafeArea(.bottom)
    }
}

struct ExpandedDetails: View {
    @Binding var environmentalData: [String: Any]

    var body: some View {
        VStack {
            if let weatherData = environmentalData["weather"] as? [String: Any],
               let temperatureArray = weatherData["temperature_2m"] as? [Float],
               let currentHour = Calendar.current.component(.hour, from: Date()) as? Int {
                let temperature = temperatureArray[currentHour % 24]
                DetailItem(icon: "thermometer", title: "Temperature", value: "\(String(format: "%.2f", temperature))°C")
            } else {
                DetailItem(icon: "thermometer", title: "Temperature", value: "N/A")
            }

            if let weatherData = environmentalData["weather"] as? [String: Any],
               let precipitation = weatherData["precipitation"] as? Float {
                DetailItem(icon: "cloud.rain", title: "Precipitation", value: "\(precipitation) mm")
            } else {
                DetailItem(icon: "cloud.rain", title: "Precipitation", value: "N/A")
            }

            if let weatherData = environmentalData["weather"] as? [String: Any],
               let windSpeed = weatherData["windspeed_10m"] as? Float {
                DetailItem(icon: "wind", title: "Wind Speed", value: "\(windSpeed) km/h")
            } else {
                DetailItem(icon: "wind", title: "Wind Speed", value: "N/A")
            }

            if let aqi = environmentalData["aqi"] as? Int {
                DetailItem(icon: "cloud.sun", title: "AQI", value: "\(aqi)")
            } else {
                DetailItem(icon: "cloud.sun", title: "AQI", value: "N/A")
            }

            if let soundIntensity = environmentalData["soundIntensity"] as? Float {
                DetailItem(icon: "waveform.path.ecg", title: "Noise Intensity", value: "\(String(format: "%.2f", soundIntensity)) dB")
            } else {
                DetailItem(icon: "waveform.path.ecg", title: "Noise Intensity", value: "N/A")
            }

            Spacer()
        }
        .padding()
        .background(Color.primary)
        .cornerRadius(30)
        .shadow(radius: 10)
        .padding(.horizontal)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .edgesIgnoringSafeArea(.bottom)
    }
}

struct DetailItem: View {
    var icon: String
    var title: String
    var value: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.green)
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundColor(.green)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 10).stroke(Color.green))
    }
}

struct LoadingView: View {
    @State private var currentMessageIndex = 0
    @State private var showTick = false
    private let messages = [
        "Setting up sensors...",
        "Establishing connections...",
        "Finalizing connections..."
    ]
    
    var body: some View {
        VStack {
            Text(showTick ? "Connections established" : messages[currentMessageIndex])
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .padding()
            
            if showTick {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.green)
            } else {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(2)
                    .padding()
            }
        }
        .background(Color.black.opacity(0.7))
        .cornerRadius(20)
        .shadow(radius: 10)
        .padding(30)
        .onAppear {
            cycleMessages()
        }
    }
    
    private func cycleMessages() {
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { timer in
            withAnimation {
                currentMessageIndex = (currentMessageIndex + 1) % messages.count
                
                if currentMessageIndex == 0 {
                    showTick = true
                    timer.invalidate()
                }
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var audioRecorder = AudioRecorder()
    @StateObject private var locationManager = LocationManager(audioRecorder: AudioRecorder())
    
    @State private var isExpanded = false
    @State private var greenIndex: Float = 0.0
    @State private var environmentalData: [String: Any] = [:]
    
    @State private var isLoading = true
    
    var body: some View {
        ZStack {
            MapView(heatmapData: $locationManager.heatmapData)
                .edgesIgnoringSafeArea(.all)
                .zIndex(0)
            
            VStack {
                Spacer()

                MinimalistBar(isExpanded: $isExpanded, greenIndex: $greenIndex)
                    .padding(.bottom, 20)
                    .frame(height: 60)
                    .animation(.easeInOut, value: isExpanded)
                
                if isExpanded {
                    ExpandedDetails(environmentalData: $environmentalData)
                        .transition(.move(edge: .bottom))
                }
            }
            .zIndex(1)
            
            if isLoading {
                LoadingView()
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .onAppear {
            startInitialSetup()
        }
        .onDisappear {
            locationManager.stopUpdatingLocation()
            audioRecorder.stopRecording()
        }
    }
    
    func startInitialSetup() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            self.isLoading = false
            locationManager.startUpdatingLocation()
            audioRecorder.startRecording()
            fetchEnvironmentalData()
        }
    }

    func fetchEnvironmentalData() {
        environmentalData = locationManager.environmentalData

        if let aqi = environmentalData["aqi"] as? Int {
            greenIndex = Float(aqi)
        }
    }
}
