//
//  ContentView.swift
//  skyup
//
//  Created by Martin Gressler on 03.09.24.
//

import SwiftUI

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
                
                parent.skytraxxUrl = url
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
            DispatchQueue.main.async {
                self.error = .NotOkResponse
            }
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

@Observable
class Progress {
    var essentialsDownload: Float = 0
    var systemDownload: Float = 0
}


struct ContentView: View {
    @State private var showingVolumePicker = false
    @State private var volumeError: AccessVolumeError?
    @State private var skytraxxUrl: URL?
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
    
    var body: some View {
        VStack {
            Text("SKYTRAXX")
            if progress.essentialsDownload > 0 {
                ProgressBar(progress: progress.essentialsDownload, label: "Downloading essential files...")
            }
            if progress.systemDownload > 0 {
                ProgressBar(progress: progress.systemDownload, label: "Downloading system files...")
            }
            Button(action: {
                showingVolumePicker = true
            }) {
                Text(
                    "Update"
                )
            }
        }.padding()
        .sheet(isPresented: $showingVolumePicker) {
            VolumePicker(skytraxxUrl: $skytraxxUrl, error: $volumeError)
        }.onChange(of: skytraxxUrl) {
            Task {
                do {
                    async let essentials = downloadArchive(url: ESSENTIALS_URL)
                    async let system = downloadArchive(url: SYSTEM_URL)
                    
                    try await essentials
                    try await system
                    
                    print("DONE")
                } catch {
                    print("Something went wrong")
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



