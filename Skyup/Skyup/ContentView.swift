//
//  ContentView.swift
//  skyup
//
//  Created by Martin Gressler on 03.09.24.
//

import SwiftUI
import Tarscape

enum ExtractError: Error {
    case Unexpected
}


func getRelativeSkytraxxPath(url: URL, extractedArchiveDirName: String) -> String {
    let range = url.path.range(of: extractedArchiveDirName + "/")
    assert(range != nil, "getRelativeSkytraxxPath was called without containing \(extractedArchiveDirName)")
    return String(url.path[range!.upperBound...])
}

func attemptWrite(buffer: Data, to url: URL, retries: Int = 3) async throws {
    var attempts = 0
    var lastError: Error?
    while attempts < retries {
        do {
            try buffer.write(to: url, options: [.atomic])
            return
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == 512 {
            // Handle weird write error
            attempts += 1
            lastError = error
            print("Retry \(attempts) for file \(url.lastPathComponent) due to stale handle.")
            // Optional: Delay before retrying
            try await Task.sleep(nanoseconds: 500_000_000) // 500 ms
        } catch {
            print("instead caught other error: \(error)")
            throw error
        }
    }
    // Throw last error if retries are exhausted
    if let lastError = lastError {
        throw lastError
    }
}

struct ContentView: View {
    @State private var showingVolumePicker = false
    @State private var volumeError: AccessVolumeError?
    @State private var skytraxxUrl: URL?
    @State private var softwareVersion: UInt64?
    @State private var deviceType: String?
    @State private var progress = Progress()
    @State private var genericErr: Error?
    
    func downloadArchive(url: String) async throws  -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            guard let archiveUrl = URL(string: url) else {
                continuation.resume(throwing: DownloadError.BadURL)
                return
            }
            let delegate = DownloadHandler(continuation: continuation) { newValue in
                assert(deviceType != nil)
                let urls = urlsByDeviceType(deviceType: deviceType!)
                if url == urls.essentialsUrl {
                    await MainActor.run {
                        progress.essentialsDownload = newValue
                    }
                } else if url == urls.systemUrl {
                    await MainActor.run {
                        progress.systemDownload = newValue
                    }
                }
            }
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let task = session.dataTask(with: archiveUrl)
            task.resume()
        }
    }
    
    func extractArchive(url: String, archive: Data) async throws {
            assert(skytraxxUrl != nil, "SKYTRAXX url is nil when trying to extract archive")
            assert(softwareVersion != nil, "Software version was nil when trying to extract archive")
            
            let tempDir = FileManager.default.temporaryDirectory
            let archiveName = URL(string: url)!.lastPathComponent
            let archiveUrl = tempDir.appendingPathComponent(archiveName)
            try archive.write(to: archiveUrl)
            let unpackedName = archiveName.replacingOccurrences(of: ".tar", with: "")
            let unpackUrl = tempDir.appendingPathComponent(unpackedName)
            try FileManager.default.extractTar(at: archiveUrl, to: unpackUrl)
            
            var objCount = 0
            var processedFiles = 0
            if let enumerator = FileManager.default.enumerator(at: unpackUrl, includingPropertiesForKeys: nil) {
                for _ in enumerator {
                    objCount += 1
                }
            }
            print("Total entries \(objCount)")
            
            
            guard let enumerator = FileManager.default.enumerator(at: unpackUrl, includingPropertiesForKeys: nil) else {
                throw ExtractError.Unexpected
            }
            
            for case let fileUrl as URL in enumerator {
                processedFiles+=1
                let relativePath = getRelativeSkytraxxPath(url: fileUrl,extractedArchiveDirName: unpackedName)
                let deviceUrl = skytraxxUrl!.appendingPathComponent(relativePath)
                print("handling File \(relativePath)")
                print("on usb device \(deviceUrl)")
                print("on temp ios \(fileUrl)")
                print(fileUrl)
                
                let isDir = Bool((try? fileUrl.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true)
                
                let progressValue = Float(processedFiles) / Float(objCount)
                let currentFile = relativePath
                await MainActor.run {
                    assert(deviceType != nil)
                    let urls = urlsByDeviceType(deviceType: deviceType!)
                    if (url == urls.essentialsUrl) {
                        progress.essentialsInstall = progressValue
                        progress.essentialsCurrentFile = currentFile
                    } else if (url == urls.systemUrl) {
                        progress.systemInstall = progressValue
                        progress.systemCurrentFile = currentFile
                    }
                }
                
                print("check if dir \(relativePath)")
                if (isDir) {
                    if !FileManager.default.fileExists(atPath: deviceUrl.path) {
                        try FileManager.default.createDirectory(atPath: deviceUrl.path, withIntermediateDirectories: true)
                    }
                    continue
                }
                
                print("Attempt read the temp file \(relativePath)")
                let tempFileBuffer = try Data(contentsOf: fileUrl)
                print("Read the temp file \(relativePath)")
                
                let fileExt = fileUrl.pathExtension
                print("Got file extension \(fileExt) for \(relativePath)")
                if fileExt == "oab" || fileExt == "owb" || fileExt == "otb" || fileExt == "oob" {
                    if FileManager.default.fileExists(atPath: deviceUrl.path) {
                        let attrs = try FileManager.default.attributesOfItem(atPath: deviceUrl.path)
                        let fileSize = attrs[FileAttributeKey.size] as! UInt64
                        
                        if fileSize >= 12 {
                            let deviceFileHandle = try FileHandle(forReadingFrom: deviceUrl)
                            let versionBuffer = try deviceFileHandle.read(upToCount: 12)
                            
                            deviceFileHandle.closeFile()
                            
                            if versionBuffer == tempFileBuffer.prefix(12) {
                                print("\(relativePath): already on device")
                                continue
                            }
                        }
                    }
                } else if fileExt == "xlb" {
                    let newSoftwareVersionData = tempFileBuffer.subdata(in: 24..<36)
                    if let newSoftwareVersion = String(data: newSoftwareVersionData, encoding: .utf8) {
                        if UInt64(newSoftwareVersion) == softwareVersion {
                            print("\(relativePath): already on device")
                            continue
                        }
                    }
                } else {
                    if FileManager.default.fileExists(atPath: deviceUrl.path) {
                        let attrs = try FileManager.default.attributesOfItem(atPath: deviceUrl.path)
                        let fileSize = attrs[FileAttributeKey.size] as! UInt64
                        
                        if fileSize > 0 {
                            let deviceFileHandle = try FileHandle(forReadingFrom: deviceUrl)
                            let compareBuffer = try deviceFileHandle.read(upToCount: 512)
                            
                            deviceFileHandle.closeFile()
                            print("Size: \(compareBuffer!.count) for \(relativePath)")
                            
                            if tempFileBuffer.subdata(in: 0..<compareBuffer!.count) == compareBuffer {
                                print("\(relativePath): already on device 512 bytes check")
                                continue
                            }
                        }
                    }
                }
                print("Try writing \(relativePath)")
                try await attemptWrite(buffer: tempFileBuffer, to: deviceUrl,  retries: 10)
            }
    }
    
    var body: some View {
        VStack {
            Text("SKYTRAXX" + (deviceType != nil ? " " + deviceType! : "")).font(Font.custom("Ethnocentric", size: 35)).padding(.bottom, 30)
            if skytraxxUrl == nil {
                Text("homeNote")
            }
            if progress.essentialsDownload > 0 {
                ProgressBar(progress: progress.essentialsDownload, label: "Downloading essential files...").padding(.bottom, 20)
            }
            if progress.systemDownload > 0 {
                ProgressBar(progress: progress.systemDownload, label: "Downloading system files...").padding(.bottom, 20)
            }
            if progress.essentialsInstall > 0 {
                ProgressBar(progress: progress.essentialsInstall, label: progress.essentialsCurrentFile).padding(.bottom, 20)
            }
            if progress.systemInstall > 0 {
                ProgressBar(progress: progress.systemInstall, label: progress.systemCurrentFile).padding(.bottom, 20)
            }
            Spacer()
            if skytraxxUrl == nil {
                Button(action: {
                    showingVolumePicker = true
                }) {
                    Text(
                        "Select SKYTRAXX"
                    ).font(Font.system(size: 20))
                }
            }
            if progress.done {
                VStack {
                    Text("The Update was successful. You can close the application now.").padding(.bottom, 20)
                    Button(action: {
                        exit(0)
                    }) {
                        Text("Close")
                    }
                }
                
            }
        }
        
        .padding(20)
        .sheet(isPresented: $showingVolumePicker) {
            VolumePicker(skytraxxUrl: $skytraxxUrl, error: $volumeError, deviceSoftwareVersion: $softwareVersion, deviceType: $deviceType)
        }.onChange(of: skytraxxUrl) {
            if (skytraxxUrl == nil) {
                return
            }
            assert(deviceType != nil, "deviceType was not assigned")
            let urls = urlsByDeviceType(deviceType: deviceType!)
            
            Task {
                do {
                    async let essentials = downloadArchive(url: urls.essentialsUrl)
                    async let system = downloadArchive(url: urls.systemUrl)
                    try await extractArchive(url: urls.essentialsUrl, archive: try await essentials)
                    try await extractArchive(url: urls.systemUrl, archive: try await system)
                    
                    skytraxxUrl?.stopAccessingSecurityScopedResource()
                } catch {
                    print(error)
                    genericErr = error
                }
            }
        }.alert(isPresented: Binding(
            get: { volumeError != nil || genericErr != nil },
            set: { _ in
                volumeError = nil
                genericErr = nil
                progress.reset()
                skytraxxUrl = nil
            }
        )) {
            if let volumeError = volumeError {
                return Alert(
                    title: Text("Error"),
                    message: Text(volumeError.userMessage()),
                    dismissButton: .default(Text("Ok"))
                )
            }
            return Alert(
                title: Text("Error"),
                message: Text(genericErr!.localizedDescription),
                dismissButton: .default(Text("Ok"))
            )
        }
    }
}





#Preview {
    ContentView()
}

func urlsByDeviceType(deviceType: String) -> (essentialsUrl: String, systemUrl: String) {
    switch (deviceType) {
    case "5mini":
        return ("https://www.skytraxx.org/skytraxx5mini/skytraxx5mini-essentials.tar", "https://www.skytraxx.org/skytraxx5mini/skytraxx5mini-system.tar")
    case "5":
        return ("https://www.skytraxx.org/skytraxx5/skytraxx5-essentials.tar", "https://www.skytraxx.org/skytraxx5/skytraxx5-system.tar")
    default:
        assert(false, "default case for deviceType hit")
        return ("", "")
    }
}
