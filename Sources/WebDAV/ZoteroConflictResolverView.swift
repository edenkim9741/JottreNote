import SwiftUI
import PencilKit

struct ZoteroConflictResolverView: View {
    @Environment(\.dismiss) private var dismiss
    let attachment: ZoteroAttachment
    let item: ZoteroItem?
    let original: ZoteroAttachment?
    let onKeepLocal: @MainActor () async -> Bool
    let onKeepServer: @MainActor () async -> Bool
    let onKeepBoth: @MainActor () async -> Bool
    let onDeleteConflictCopy: @MainActor () async -> Bool

    @State private var isResolving = false
    @State private var localSize: Int64 = 0
    @State private var serverSize: Int64?
    @State private var strokeCount = 0

    private var localFileURL: URL? {
        guard let path = attachment.conflictLocalPath ?? attachment.localCachePath else { return nil }
        return URL(fileURLWithPath: path)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Label(String(localized: "zotero.conflict.badge"), systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(String(localized: "zotero.conflict.explanation"))
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                if let date = attachment.conflictCreatedAt {
                    LabeledContent(String(localized: "zotero.conflict.detectedAt"), value: date.formatted(date: .abbreviated, time: .shortened))
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(localized: "zotero.conflict.localVersion")).font(.headline)
                    LabeledContent(String(localized: "zotero.conflict.fileSize"), value: ByteCountFormatter.string(fromByteCount: localSize, countStyle: .file))
                    LabeledContent(String(localized: "zotero.conflict.modified"), value: attachment.conflictCreatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    LabeledContent(String(localized: "zotero.conflict.strokes"), value: "\(strokeCount)")
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(localized: "zotero.conflict.serverVersion")).font(.headline)
                    LabeledContent(String(localized: "zotero.conflict.fileSize"), value: serverSize.map {
                        ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                    } ?? String(localized: "zotero.conflict.notAvailable"))
                    LabeledContent(String(localized: "zotero.conflict.modified"), value: serverModifiedText)
                    LabeledContent(String(localized: "zotero.conflict.checksum"), value: original?.remoteMD5 ?? original?.md5 ?? String(localized: "zotero.conflict.notAvailable"))
                }
                Spacer(minLength: 0)
                VStack(spacing: 10) {
                    actionButton("zotero.conflict.keepLocal", symbol: "ipad.and.pencil", prominent: true, action: onKeepLocal)
                    actionButton("zotero.conflict.keepServer", symbol: "icloud.and.arrow.down", action: onKeepServer)
                    actionButton("zotero.conflict.keepBoth", symbol: "doc.on.doc", action: onKeepBoth)
                    actionButton("zotero.conflict.deleteCopy", symbol: "trash", destructive: true, action: onDeleteConflictCopy)
                }
            }
            .padding(20)
            .navigationTitle(item?.title ?? String(localized: "zotero.conflict.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action.cancel")) { dismiss() }
                        .disabled(isResolving)
                }
            }
            .overlay {
                if isResolving {
                    ProgressView(String(localized: "zotero.conflict.resolving"))
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .task { loadLocalDetails() }
        }
        .presentationDetents([.large])
    }

    private var serverModifiedText: String {
        guard let milliseconds = original?.modificationTimeMilliseconds else {
            return String(localized: "zotero.conflict.notAvailable")
        }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
            .formatted(date: .abbreviated, time: .shortened)
    }

    @ViewBuilder
    private func actionButton(
        _ key: String,
        symbol: String,
        prominent: Bool = false,
        destructive: Bool = false,
        action: @escaping @MainActor () async -> Bool
    ) -> some View {
        let button = Button {
            guard !isResolving else { return }
            Task { @MainActor in
                isResolving = true
                let succeeded = await action()
                isResolving = false
                if succeeded { dismiss() }
            }
        } label: {
            Label {
                Text(LocalizedStringKey(key))
            } icon: {
                Image(systemName: symbol)
            }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(isResolving)
        if destructive {
            button.buttonStyle(.bordered)
                .tint(.red)
        } else if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func loadLocalDetails() {
        if let path = original?.localCachePath,
           let attributes = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attributes[.size] as? NSNumber {
            serverSize = size.int64Value
        }
        guard let localFileURL, let data = try? Data(contentsOf: localFileURL) else { return }
        localSize = Int64(data.count)
        if let hybrid = try? HybridPDFManager.load(data: data) {
            strokeCount = hybrid.drawing.strokes.count
        } else if let pdfData = HybridPDFManager.embeddedJotData(in: data),
                  let jot = try? PropertyListDecoder().decode(Jot.self, from: pdfData),
                  let drawing = try? PKDrawing(data: jot.drawing) {
            strokeCount = drawing.strokes.count
        }
    }
}
