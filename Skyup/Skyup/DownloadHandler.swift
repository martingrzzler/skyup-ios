//
//  DownloadHandler.swift
//  Skyup
//
//  Created by Martin Gressler on 17.10.24.
//

import Foundation

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
    let onProgressChange: (Float) async -> Void
    
    init(
        continuation: CheckedContinuation<Data, Error>,
        onProgressChange: @escaping (Float) async -> Void
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
        Task {
         await onProgressChange(progress)
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: archiveData)
        }
    }
}
