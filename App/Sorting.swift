import PlumeKit
import SwiftUI

enum SortField: String, CaseIterable, Identifiable {
    case name, modified, size, kind
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .name: "Name"
        case .modified: "Date Modified"
        case .size: "Size"
        case .kind: "Kind"
        }
    }
}

struct SortOrder: Equatable {
    var field: SortField = .name
    var ascending = true

    func sorted(_ items: [RemoteItem]) -> [RemoteItem] {
        items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let order = compare(a, b)
            if order == .orderedSame {
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private func compare(_ a: RemoteItem, _ b: RemoteItem) -> ComparisonResult {
        switch field {
        case .name:
            return a.name.localizedStandardCompare(b.name)
        case .modified:
            return compareValues(a.modified ?? .distantPast, b.modified ?? .distantPast)
        case .size:
            return compareValues(a.size, b.size)
        case .kind:
            let kindA = a.isDirectory ? "" : (a.name as NSString).pathExtension.lowercased()
            let kindB = b.isDirectory ? "" : (b.name as NSString).pathExtension.lowercased()
            return kindA.localizedStandardCompare(kindB)
        }
    }

    private func compareValues<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }
}

struct SortMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Menu("Sort", systemImage: "arrow.up.arrow.down") {
            Picker("Sort By", selection: $model.sortOrder.field) {
                ForEach(SortField.allCases) { field in
                    Text(field.title).tag(field)
                }
            }
            .pickerStyle(.inline)
            Picker("Order", selection: $model.sortOrder.ascending) {
                Text(ascendingTitle).tag(true)
                Text(descendingTitle).tag(false)
            }
            .pickerStyle(.inline)
        }
        .accessibilityLabel("Sort")
    }

    private var ascendingTitle: LocalizedStringKey {
        switch model.sortOrder.field {
        case .name, .kind: "A to Z"
        case .modified: "Oldest First"
        case .size: "Smallest First"
        }
    }

    private var descendingTitle: LocalizedStringKey {
        switch model.sortOrder.field {
        case .name, .kind: "Z to A"
        case .modified: "Newest First"
        case .size: "Largest First"
        }
    }
}

struct SkeletonList: View {
    var rows = 12
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmer = false

    var body: some View {
        List(0..<rows, id: \.self) { index in
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 6)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 6) {
                    Capsule().frame(width: nameWidth(index), height: 12)
                    Capsule().frame(width: 90, height: 9).opacity(0.7)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.quaternary)
            .padding(.vertical, 2)
            .opacity(reduceMotion ? 1 : (shimmer ? 0.45 : 1))
        }
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("Loading")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { shimmer = true }
        }
    }

    private func nameWidth(_ index: Int) -> CGFloat {
        [180, 130, 210, 150, 110, 190, 160, 140, 200, 120, 170, 150][index % 12]
    }
}
