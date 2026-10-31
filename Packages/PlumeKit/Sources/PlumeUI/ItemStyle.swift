import PlumeKit
import SwiftUI
import UniformTypeIdentifiers

public extension RemoteItem {
    /// SF Symbol for the item's kind.
    var symbolName: String {
        if isDirectory { return isShared ? "folder.fill.badge.person.crop" : "folder.fill" }
        let type = utType
        if type.conforms(to: .pdf) { return "doc.richtext.fill" }
        if type.conforms(to: .image) { return "photo.fill" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "film.fill" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .spreadsheet) { return "tablecells.fill" }
        if type.conforms(to: .presentation) { return "rectangle.on.rectangle.angled.fill" }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) { return "chevron.left.forwardslash.chevron.right" }
        if type.conforms(to: .text) || type.conforms(to: .rtf) { return "doc.text.fill" }
        return "doc.fill"
    }

    var symbolColor: Color {
        if isDirectory { return .accentColor }
        let type = utType
        if type.conforms(to: .pdf) { return .red }
        if type.conforms(to: .image) { return .orange }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .purple }
        if type.conforms(to: .audio) { return .pink }
        if type.conforms(to: .spreadsheet) { return .green }
        if type.conforms(to: .presentation) { return .orange }
        return .secondary
    }

    /// "1.2 MB · Yesterday" — the secondary line of a row.
    var summary: String {
        var parts: [String] = []
        if !isDirectory || size > 0 { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        if let modified { parts.append(modified.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }
}
