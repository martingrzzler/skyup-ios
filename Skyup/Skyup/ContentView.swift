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

enum AccessVolumeError: Error {
    case NotFound
    case WrongVolume
    case AccessDenied
    case Not5Mini
    case Unexpected
    
    func userMessage() -> String {
        switch self {
        case .NotFound:
            return "SKYTRAXX could not be found"
        case .AccessDenied:
            return "Failed to access SKYTRAXX"
        case .WrongVolume:
            return "You selected the wrong folder. Please select SKYTRAXX"
        case .Not5Mini:
            return "The SKYTRAXX Device is not the 5 Mini"
        case .Unexpected:
            return "Oops.. an unexpected error occured"
        }
    }
}

func parseLines(fileContent: String) -> [String: String] {
    var dict = [String: String]()
    let lines = fileContent.components(separatedBy: .newlines)
    
    for line in lines {
        let parts = line.split(separator: "=", maxSplits: 1).map { String($0) }
        if parts.count == 2 {
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
            dict[key] = value
        }
    }
    
    return dict
}

struct VolumePicker: UIViewControllerRepresentable {
    @Binding var skytraxxUrl: URL?
    @Binding var error: AccessVolumeError?
    @Binding var deviceSoftwareVersion: UInt64?
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: VolumePicker
        init(_ parent: VolumePicker) {
            self.parent = parent
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if urls.count != 1 {
                parent.error = .WrongVolume
                return
            }
            
            let url: URL = urls.first!
            guard url.startAccessingSecurityScopedResource() else {
                parent.error = .AccessDenied
                return
            }
            
            do {
                let volumeName = try url.resourceValues(forKeys: [.volumeNameKey])
                if volumeName.volumeName != "SKYTRAXX" {
                    url.stopAccessingSecurityScopedResource()
                    parent.error = .WrongVolume
                    return
                }
                
                let deviceInfoFileUrl = url.appendingPathComponent(".sys/hwsw.info")
                let deviceInfoData = try String(contentsOf: deviceInfoFileUrl)
                let dict = parseLines(fileContent: deviceInfoData)
                
                
                guard let deviceType = dict["hw"] else {
                    parent.error = .Not5Mini
                    return
                }
                if deviceType != "5mini" {
                    parent.error = .Not5Mini
                    return
                }
                
                guard let softwareVersion = dict["sw"] else {
                    parent.error = .Not5Mini
                    return
                }
                
                
                
                parent.skytraxxUrl = url
                let softwareVersionNum = softwareVersion.replacingOccurrences(of: "build-", with: "")
                parent.deviceSoftwareVersion = UInt64(softwareVersionNum)!
            } catch {
                parent.error = .Unexpected
            }
        }
        
    }
    
    
    func makeUIViewController(
        context: Context
    ) -> some UIViewController {
        let documentPicker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.folder]
        )
        documentPicker.delegate = context.coordinator
        documentPicker.allowsMultipleSelection = false
        
        return documentPicker
    }
    
    func updateUIViewController(
        _ uiViewController: UIViewControllerType,
        context: Context
    ) {
        uiViewController.dismiss(animated: true)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
}

enum DownloadError: Error {
    case NotOkResponse
    case BadURL
}


class DownloadHandler: NSObject, URLSessionDataDelegate {
    private var error: DownloadError?
    private var totalBytes = 0
    private var archiveData = Data()
    private var downloadedBytes = 0
    let continuation: CheckedContinuation<Data, Error>
    let onProgressChange: (Float) -> Void
    
    init(
        continuation: CheckedContinuation<Data, Error>,
        onProgressChange: @escaping (Float) -> Void
    ) {
        self.onProgressChange = onProgressChange
        self.continuation = continuation
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
            totalBytes = Int(truncatingIfNeeded: response.expectedContentLength)
            completionHandler(.allow)
        } else {
            self.error = .NotOkResponse
            completionHandler(.cancel)
            continuation.resume(throwing: DownloadError.NotOkResponse)
        }
    }
    
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        archiveData.append(data)
        downloadedBytes += data.count
        let progress = Float(downloadedBytes) / Float(totalBytes)
        onProgressChange(progress)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: archiveData)
        }
    }
}

enum ExtractError: Error {
    case Unexpected
}

@Observable
class Progress {
    var essentialsDownload: Float = 0
    var essentialsInstall: Float = 0
    var essentialsCurrentFile: String = ""
    var systemDownload: Float = 0
    var systemInstall: Float = 0
    var systemCurrentFile: String = ""
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
    
    func downloadArchive(url: String) async throws  -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            guard let archiveUrl = URL(string: url) else {
                continuation.resume(throwing: DownloadError.BadURL)
                return
            }
            let delegate = DownloadHandler(continuation: continuation) { newValue in
                if url == ESSENTIALS_URL {
                    progress.essentialsDownload = newValue
                } else if url == SYSTEM_URL {
                    progress.systemDownload = newValue
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
                        
                        if fileSize < 12 {
                            continue
                        }
                        
                        let deviceFileHandle = try FileHandle(forReadingFrom: deviceUrl)
                        let versionBuffer = try deviceFileHandle.read(upToCount: 12)
                        
                        deviceFileHandle.closeFile()
                        
                        if versionBuffer == tempFileBuffer.prefix(12) {
                            print("\(relativePath): already on device")
                            continue
                        }
                    }
                    try tempFileBuffer.write(to: deviceUrl, options: [.atomic])
                } else if fileExt == "xlb" {
                    let newSoftwareVersionData = tempFileBuffer.subdata(in: 24..<36)
                    if let newSoftwareVersion = String(data: newSoftwareVersionData, encoding: .utf8) {
                        if UInt64(newSoftwareVersion) == softwareVersion {
                            print("\(relativePath): already on device")
                            continue
                        }
                    }
                    try tempFileBuffer.write(to: deviceUrl, options: [.atomic])
                } else {
                    try tempFileBuffer.write(to: deviceUrl, options: [.atomic])
                }
            }
    }
    
    var body: some View {
        VStack {
            Text("SKYTRAXX").font(Font.custom("Ethnocentric", size: 35)).padding(.bottom, 30)
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

        }
        
        .padding(20)
        .sheet(isPresented: $showingVolumePicker) {
            VolumePicker(skytraxxUrl: $skytraxxUrl, error: $volumeError, deviceSoftwareVersion: $softwareVersion)
        }.onChange(of: skytraxxUrl) {
            Task {
                do {
                    async let essentials = downloadArchive(url: ESSENTIALS_URL)
                    async let system = downloadArchive(url: SYSTEM_URL)
                    try await extractArchive(url: ESSENTIALS_URL, archive: try await essentials)
                    try await extractArchive(url: SYSTEM_URL, archive: try await system)
                } catch {
                    print("Something went wrong")
                    print(error)
                }
            }
        }.alert( isPresented: Binding(get: { return volumeError != nil }, set: { newValue in volumeError = nil })
            ) {
                Alert(title: Text("Error"),
                      message: Text(volumeError!.userMessage()),
                      dismissButton: .default(Text("Ok"))
                )
        }
    }
}

struct ProgressBar: View {
    var progress: Float
    var label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .font(.body)
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.body)
            }
            
            ProgressView(value: Double(progress))
                .progressViewStyle(LinearProgressViewStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 5)
    }
}



#Preview {
    ContentView()
}
