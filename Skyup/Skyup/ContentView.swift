//
//  ContentView.swift
//  skyup
//
//  Created by Martin Gressler on 03.09.24.
//

import SwiftUI
import Tarscape

let ESSENTIALS_URL = "https://www.skytraxx.org/skytraxx5mini/skytraxx5mini-essentials.tar"
let SYSTEM_URL = "https://www.skytraxx.org/skytraxx5mini/skytraxx5mini-system.tar"

enum ExtractError: Error {
    case Unexpected
}


func getRelativeSkytraxxPath(url: URL, extractedArchiveDirName: String) -> String {
    let range = url.path.range(of: extractedArchiveDirName + "/")
    assert(range != nil, "getRelativeSkytraxxPath was called without containing \(extractedArchiveDirName)")
    return String(url.path[range!.upperBound...])
}

struct ContentView: View {
    @State private var showingVolumePicker = false
    @State private var volumeError: AccessVolumeError?
    @State private var skytraxxUrl: URL?
    @State private var softwareVersion: UInt64?
    @State private var progress = Progress()
    @State private var genericErr: Error?
    
    func downloadArchive(url: String) async throws  -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            guard let archiveUrl = URL(string: url) else {
                continuation.resume(throwing: DownloadError.BadURL)
                return
            }
            let delegate = DownloadHandler(continuation: continuation) { newValue in
                if url == ESSENTIALS_URL {
                    await MainActor.run {
                        progress.essentialsDownload = newValue
                    }
                } else if url == SYSTEM_URL {
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
                
                let isDir = Bool((try? fileUrl.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true)
                
                let progressValue = Float(processedFiles) / Float(objCount)
                let currentFile = relativePath
                await MainActor.run {
                    if (url == ESSENTIALS_URL) {
                        progress.essentialsInstall = progressValue
                        progress.essentialsCurrentFile = currentFile
                    } else if (url == SYSTEM_URL) {
                        progress.systemInstall = progressValue
                        progress.systemCurrentFile = currentFile
                    }
                }
                
                
                if (isDir) {
                    if !FileManager.default.fileExists(atPath: deviceUrl.path) {
                        try FileManager.default.createDirectory(atPath: deviceUrl.path, withIntermediateDirectories: true)
                    }
                    continue
                }
                
                let tempFileBuffer = try Data(contentsOf: fileUrl)
                
                let fileExt = fileUrl.pathExtension
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
                }
                try tempFileBuffer.write(to: deviceUrl, options: [.atomic])
            }
    }
    
    var body: some View {
        VStack {
            Text("SKYTRAXX").font(Font.custom("Ethnocentric", size: 35)).padding(.bottom, 30)
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
                Text("The Update was successful. You can close the application now.")
            }
        }
        
        .padding(20)
        .sheet(isPresented: $showingVolumePicker) {
            VolumePicker(skytraxxUrl: $skytraxxUrl, error: $volumeError, deviceSoftwareVersion: $softwareVersion)
        }.onChange(of: skytraxxUrl) {
            if (skytraxxUrl == nil) {
                return
            }
            Task {
                do {
                    async let essentials = downloadArchive(url: ESSENTIALS_URL)
                    async let system = downloadArchive(url: SYSTEM_URL)
                    try await extractArchive(url: ESSENTIALS_URL, archive: try await essentials)
                    try await extractArchive(url: SYSTEM_URL, archive: try await system)
                    
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
