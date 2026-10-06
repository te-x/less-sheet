/// Footer facts copied from a Parquet document. Inspection never reads pages.
public protocol ParquetMetadataInspecting: Sendable {
    func parquetFileInfo() -> ParquetFileInfo?
    func parquetSchemaColumn(_ index: Int) -> ParquetSchemaColumn?
    func parquetRowGroup(_ index: UInt64) -> ParquetRowGroupInfo?
}

public extension ParquetMetadataInspecting {
    func parquetFileInfo() -> ParquetFileInfo? { nil }
    func parquetSchemaColumn(_ index: Int) -> ParquetSchemaColumn? { nil }
    func parquetRowGroup(_ index: UInt64) -> ParquetRowGroupInfo? { nil }
}

public struct ParquetFileInfo: Sendable {
    public var fileBytes: UInt64
    public var rows: UInt64
    public var rowGroups: UInt64
    public var columns: Int
    public var formatVersion: Int
    public var compression: String
    public var writer: String

    public init(fileBytes: UInt64, rows: UInt64, rowGroups: UInt64, columns: Int,
                formatVersion: Int, compression: String, writer: String) {
        self.fileBytes = fileBytes
        self.rows = rows
        self.rowGroups = rowGroups
        self.columns = columns
        self.formatVersion = formatVersion
        self.compression = compression
        self.writer = writer
    }
}

public struct ParquetSchemaColumn: Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let type: String

    public init(id: Int, name: String, type: String) {
        self.id = id
        self.name = name
        self.type = type
    }
}

public struct ParquetRowGroupInfo: Identifiable, Sendable {
    public let id: UInt64
    public let firstRow: UInt64
    public let rows: UInt64
    public let compressedBytes: UInt64
    public let uncompressedBytes: UInt64

    public init(id: UInt64, firstRow: UInt64, rows: UInt64,
                compressedBytes: UInt64, uncompressedBytes: UInt64) {
        self.id = id
        self.firstRow = firstRow
        self.rows = rows
        self.compressedBytes = compressedBytes
        self.uncompressedBytes = uncompressedBytes
    }
}
