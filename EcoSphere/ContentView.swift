//
//  ContentView.swift
//  EcoSphere
//
//  Created by Manab Kumar Biswas on 08/10/2024.
//
import SwiftUI
import CoreLocation
import AVFoundation

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    
    @Published var location: CLLocationCoordinate2D? = nil
    private let fileName = "locationData.txt"
    
    override init() {
        super.init()
        self.locationManager.delegate = self
        checkLocationAuthorization()
    }
    
    private func checkLocationAuthorization() {
        let status = locationManager.authorizationStatus
        
        if status == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else if status == .authorizedWhenInUse || status == .authorizedAlways {
            startUpdatingLocation()
        } else {
            print("Location permission denied")
        }
    }

    func startUpdatingLocation() {
        print("Starting location updates")
        self.locationManager.startUpdatingLocation()
    }

    func stopUpdatingLocation() {
        print("Stopping location updates")
        self.locationManager.stopUpdatingLocation()
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.first {
            DispatchQueue.main.async {
                self.location = location.coordinate
                self.saveLocationData(location: location)
                print("Location updated: \(location.coordinate.latitude), \(location.coordinate.longitude)")
            }
        }
    }
    
    private func saveLocationData(location: CLLocation) {
        let latitude = location.coordinate.latitude
        let longitude = location.coordinate.longitude
        let timestamp = Date()

        let dataString = "Time: \(timestamp), Latitude: \(latitude), Longitude: \(longitude)\n"
        
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let fileURL = dir.appendingPathComponent(fileName)
            
            do {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    let fileHandle = try FileHandle(forWritingTo: fileURL)
                    fileHandle.seekToEndOfFile()
                    if let data = dataString.data(using: .utf8) {
                        fileHandle.write(data)
                    }
                    fileHandle.closeFile()
                } else {
                    try dataString.write(to: fileURL, atomically: true, encoding: .utf8)
                }
            } catch {
                print("Error saving location data: \(error.localizedDescription)")
            }
        }
    }
}

class AudioRecorder: NSObject, ObservableObject {
    private var audioRecorder: AVAudioRecorder?
    
    @Published var isRecording = false

    func startRecording() {
        let audioFilename = getDocumentsDirectory().appendingPathComponent("recording.m4a")
        
        let audioSession = AVAudioSession.sharedInstance()
        
        do {
            try audioSession.setCategory(.playAndRecord, options: [.allowBluetooth, .defaultToSpeaker, .mixWithOthers])
            
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        } catch {
            print("Failed to set up audio session: \(error.localizedDescription)")
            return
        }
        
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
            print("Continuous audio recording started")
        } catch {
            print("Failed to start recording: \(error.localizedDescription)")
        }
    }
    
    func stopRecording() {
        if isRecording {
            audioRecorder?.stop()
            isRecording = false
            print("Audio recording stopped")
            
            let audioSession = AVAudioSession.sharedInstance()
            do {
                try audioSession.setActive(false)
            } catch {
                print("Failed to deactivate audio session: \(error.localizedDescription)")
            }
        }
    }

    private func getDocumentsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0]
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
            print("LocationView appeared - start updating location")
            locationManager.startUpdatingLocation()
        }
        .onDisappear {
            print("LocationView disappeared - stop updating location")
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
            print("MicrophoneView appeared - start recording")
            audioRecorder.startRecording()
        }
        .onDisappear {
            print("MicrophoneView disappeared - stop recording")
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
