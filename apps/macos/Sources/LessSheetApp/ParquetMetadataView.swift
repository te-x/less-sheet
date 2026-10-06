import AppKit
import Contracts
import SwiftUI

struct ParquetMetadataView: View {
    let session: any DocumentSession
    let info: ParquetFileInfo
    let name: String
    @State private var section = 0
    @State private var first: UInt64 = 0
    @State private var columns: [ParquetSchemaColumn] = []
    @State private var groups: [ParquetRowGroupInfo] = []
    private let pageSize: UInt64 = 64

    private var total: UInt64 { section == 1 ? UInt64(info.columns) : info.rowGroups }

    var body: some View {
        VStack(spacing: 12) {
            Text(name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(name)
            Picker("Metadata section", selection: $section) {
                Text("Overview").tag(0)
                Text("Schema").tag(1)
                Text("Row Groups").tag(2)
            }
            .pickerStyle(.segmented)
            if section == 0 {
                Form {
                    LabeledContent("Rows", value: info.rows.formatted())
                    LabeledContent("Columns", value: info.columns.formatted())
                    LabeledContent("Row groups", value: info.rowGroups.formatted())
                    LabeledContent("File size", value: size(info.fileBytes))
                    LabeledContent("Parquet format version", value: info.formatVersion.formatted())
                    LabeledContent("Compression", value: info.compression)
                    LabeledContent("Written by", value: info.writer.isEmpty ? "Not recorded" : info.writer)
                }
                .formStyle(.grouped)
                .textSelection(.enabled)
            } else if section == 1 {
                Table(columns) {
                    TableColumn("Column", value: \.name).width(min: 130, ideal: 180)
                    TableColumn("Type", value: \.type)
                }
                .textSelection(.enabled)
            } else {
                List(groups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Row group \(group.id + 1)").font(.headline)
                        Text("\(group.rows.formatted()) rows · starts at row \((group.firstRow + 1).formatted())")
                        Text("\(size(group.compressedBytes)) compressed · \(size(group.uncompressedBytes)) uncompressed")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .textSelection(.enabled)
                .overlay {
                    if groups.isEmpty { Text("No row groups").foregroundStyle(.secondary) }
                }
            }
            if section != 0 && total > pageSize {
                HStack {
                    Button("Previous") { first -= pageSize; loadPage() }.disabled(first == 0)
                    Spacer()
                    Text("\(first + 1)–\(min(total, first + pageSize)) of \(total)")
                        .monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Button("Next") { first += pageSize; loadPage() }.disabled(first + pageSize >= total)
                }
            }
        }
        .padding(20)
        .onChange(of: section) { _, _ in first = 0; loadPage() }
    }

    private func loadPage() {
        columns = []
        groups = []
        guard section != 0 else { return }
        let end = min(total, first + pageSize)
        if section == 1 {
            columns = (first..<end).compactMap { session.parquetSchemaColumn(Int($0)) }
        } else {
            groups = (first..<end).compactMap { session.parquetRowGroup($0) }
        }
    }

    private func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}

extension AppDelegate {
    func presentParquetMetadata() {
        let model = DocumentModel.shared
        guard let session = model.session, let info = session.parquetFileInfo() else { return }
        if let window = parquetMetadataWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 580),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.title = "Parquet Metadata"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 540, height: 400)
        window.contentView = NSHostingView(rootView: ParquetMetadataView(session: session, info: info, name: model.path))
        window.center()
        window.makeKeyAndOrderFront(nil)
        parquetMetadataWindow = window
    }

    func closeParquetMetadata() {
        parquetMetadataWindow?.close()
        parquetMetadataWindow = nil
    }
}
