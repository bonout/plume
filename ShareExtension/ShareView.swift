import PlumeKit
import PlumeUI
import SwiftUI

struct ShareView: View {
    let model: ShareModel

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView("Preparing…").padding(40)
        case .signedOut:
            message("Open Plume and sign in to your server first.", symbol: "person.crop.circle.badge.exclamationmark")
        case .picking:
            if let repository = model.repository {
                FolderPicker(repository: repository, title: title, initial: model.lastFolder,
                             onPick: { model.save(to: $0) }, onCancel: { model.cancel() })
            }
        case .uploading:
            VStack(spacing: 16) {
                Text(title).font(.headline)
                ProgressView(model.progress).frame(maxWidth: 320)
            }
            .padding(40)
        case .done:
            message("Saved", symbol: "checkmark.circle.fill")
        case .failed(let text):
            message(text, symbol: "exclamationmark.triangle.fill")
        }
    }

    private var title: String {
        model.files.count == 1 ? "Save “\(model.files[0].lastPathComponent)”" : "Save \(model.files.count) Files"
    }

    private func message(_ text: String, symbol: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.tint)
            Text(text).multilineTextAlignment(.center)
            Button("Close") { model.close() }.keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(minWidth: 320)
    }
}
