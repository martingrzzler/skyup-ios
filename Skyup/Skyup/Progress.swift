//
//  Progress.swift
//  Skyup
//
//  Created by Martin Gressler on 17.10.24.
//

import Foundation
import SwiftUI


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

@Observable
class Progress {
    var essentialsDownload: Float = 0
    var essentialsInstall: Float = 0
    var essentialsCurrentFile: String = ""
    var systemDownload: Float = 0
    var systemInstall: Float = 0
    var systemCurrentFile: String = ""
    
    var done: Bool {
        get {
           return Int(essentialsInstall * 100) == 100 && Int(essentialsDownload * 100) == 100 &&
            Int(systemInstall * 100) == 100 && Int(systemDownload * 100) == 100
        }
    }
    
    func reset() {
        essentialsDownload = 0
        essentialsInstall = 0
        essentialsCurrentFile = ""
        systemDownload = 0
        systemInstall = 0
        systemCurrentFile = ""
    }
}
