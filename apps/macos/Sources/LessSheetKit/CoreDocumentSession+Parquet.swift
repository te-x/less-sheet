import CLessSheet
import Contracts
import Foundation

extension CoreDocumentSession {
    public func parquetFileInfo() -> ParquetFileInfo? {
        lock.lock()
        defer { lock.unlock() }
        var info = ls_parquet_info()
        guard !isClosed, ls_parquet_info_get(doc, &info) else { return nil }
        let codecs = ["Uncompressed", "Snappy", "Gzip", "LZO", "Brotli", "LZ4", "Zstd", "LZ4 raw"]
        let compression = codecs.enumerated().compactMap { index, name in
            info.codec_mask & (1 << index) != 0 ? name : nil
        }.joined(separator: ", ")
        return ParquetFileInfo(
            fileBytes: info.file_bytes, rows: info.rows, rowGroups: info.row_groups,
            columns: Int(info.columns), formatVersion: Int(info.format_version),
            compression: compression.isEmpty ? "None (empty file)" : compression,
            writer: Self.copyCell(ls_str(ptr: info.created_by.ptr, len: min(info.created_by.len, 4096)))
        )
    }

    public func parquetSchemaColumn(_ index: Int) -> ParquetSchemaColumn? {
        lock.lock()
        defer { lock.unlock() }
        var column = ls_parquet_column()
        guard !isClosed, let ordinal = UInt32(exactly: index),
              ls_parquet_column_get(doc, ordinal, &column) else { return nil }
        let logical = withUnsafePointer(to: &column.logical_type) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 128) { String(cString: $0) }
        }
        let physical = Self.copyCell(column.physical_type)
        let type = [physical, logical, column.nullable ? "Nullable" : "Required"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        let name = Self.copyCell(ls_str(ptr: column.name.ptr, len: min(column.name.len, 1024)))
        return ParquetSchemaColumn(id: index, name: name, type: type)
    }

    public func parquetRowGroup(_ index: UInt64) -> ParquetRowGroupInfo? {
        lock.lock()
        defer { lock.unlock() }
        var group = ls_parquet_row_group()
        guard !isClosed, ls_parquet_row_group_get(doc, index, &group) else { return nil }
        return ParquetRowGroupInfo(
            id: index, firstRow: group.first_row, rows: group.rows,
            compressedBytes: group.compressed_bytes, uncompressedBytes: group.uncompressed_bytes
        )
    }
}
