//
//  ContentView.swift
//  EcoSphere
//
//  Created by Manab Kumar Biswas on 08/10/2024.
//

import SwiftUI
import Foundation
import CoreLocation
import AVFoundation

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private var locationBatch: [[String: Any]] = []
    private var uploadTimer: Timer?

    @Published var location: CLLocationCoordinate2D? = nil

    override init() {
        super.init()
        self.locationManager.delegate = self
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
                print("Location updated: \(location.coordinate.latitude), \(location.coordinate.longitude)")
            }
        }
    }

    private func addLocationToBatch(location: CLLocation) {
        let data: [String: Any] = [
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "timestamp": Date().timeIntervalSince1970
        ]
        locationBatch.append(data)
        saveLocationDataLocally(data: data)
    }

    private func saveLocationDataLocally(data: [String: Any]) {
        let fileURL = getDocumentsDirectory().appendingPathComponent("locationData.txt")
        let dataString = "Latitude: \(data["latitude"]!), Longitude: \(data["longitude"]!), Timestamp: \(data["timestamp"]!)\n"

        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let fileHandle = try FileHandle(forWritingTo: fileURL)
                fileHandle.seekToEndOfFile()
                fileHandle.write(dataString.data(using: .utf8)!)
                fileHandle.closeFile()
            } else {
                try dataString.write(to: fileURL, atomically: true, encoding: .utf8)
            }
            print("Location data saved locally.")
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

        fetchWeatherData(latitude: latitude, longitude: longitude) { weatherData in
            var batchWithWeather = self.locationBatch
            batchWithWeather.append(["weatherData": weatherData])
            
            let url = URL(string: "https://ecosphere-421ef-default-rtdb.europe-west1.firebasedatabase.app/locationData.json")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let batchData = ["locations": batchWithWeather]
            request.httpBody = try? JSONSerialization.data(withJSONObject: batchData, options: [])

            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error {
                    print("Failed to upload location batch: \(error)")
                } else {
                    print("Location batch with weather data uploaded to Firebase")
                    self.locationBatch.removeAll()
                }
            }.resume()
        }
    }

    private func fetchWeatherData(latitude: Double, longitude: Double, completion: @escaping ([String: Any]) -> Void) {
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)&hourly=temperature_2m,precipitation,cloudcover,windspeed_10m"
        guard let url = URL(string: urlString) else { return }

        URLSession.shared.dataTask(with: url) { data, response, error in
            if let data = data {
                do {
                    let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
                    let hourlyData = json?["hourly"] as? [String: Any] ?? [:]
                    completion(hourlyData)
                } catch {
                    print("Error decoding weather data: \(error)")
                }
            } else if let error = error {
                print("Error fetching weather data: \(error)")
            }
        }.resume()
    }

    private func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}

class AudioRecorder: NSObject, ObservableObject {
    private var audioRecorder: AVAudioRecorder?
    private var recordingTimer: Timer?

    @Published var isRecording = false
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
            audioRecorder?.record()
            isRecording = true
            print("Audio recording started")
        } catch {
            print("Failed to start recording: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        recordingTimer?.invalidate()
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

struct LocationView: View {
    @StateObject var locationManager = LocationManager()

    var body: some View {
        VStack {
            if let location = locationManager.location {
                Text("Latitude: \(location.latitude)")
                Text("Longitude: \(location.longitude)")
            } else {
                Text("Fetching location...")
            }
        }
        .padding()
        .onAppear {
            locationManager.startUpdatingLocation()
        }
        .onDisappear {
            locationManager.stopUpdatingLocation()
        }
    }
}

struct MicrophoneView: View {
    @StateObject var audioRecorder = AudioRecorder()

    var body: some View {
        VStack {
            if audioRecorder.isRecording {
                Text("Recording audio...")
            }
        }
        .padding()
        .onAppear {
            audioRecorder.startRecording()
        }
        .onDisappear {
            audioRecorder.stopRecording()
        }
    }
}

struct ContentView: View {
    var body: some View {
        VStack {
            LocationView()
            Divider()
            MicrophoneView()
        }
        .padding()
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
