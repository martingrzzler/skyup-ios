//
//  VolumePicker.swift
//  Skyup
//
//  Created by Martin Gressler on 17.10.24.
//

import SwiftUI

enum AccessVolumeError: Error {
    case NotFound
    case WrongVolume
    case AccessDenied
    case Not5Mini
    case Unexpected
    
    func userMessage() -> LocalizedStringKey {
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

