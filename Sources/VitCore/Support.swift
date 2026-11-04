import os

/// A minimal unfair lock. The parser runs on the PTY thread and the renderer snapshots on the main
/// thread; both hold this only briefly.
public final class UnfairLock: @unchecked Sendable {
    private let p: UnsafeMutablePointer<os_unfair_lock>
    public init() {
        p = .allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
    }
    deinit { p.deallocate() }
    @inline(__always) public func lock() { os_unfair_lock_lock(p) }
    @inline(__always) public func unlock() { os_unfair_lock_unlock(p) }
    @inline(__always) public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(p)
        defer { os_unfair_lock_unlock(p) }
        return try body()
    }
}

/// Interned multi-scalar grapheme clusters, referenced from cells flagged `.grapheme`.
public final class GraphemeTable {
    public private(set) var clusters: [[UInt32]] = []
    private var index: [[UInt32]: UInt32] = [:]

    public init() {}

    /// Most distinct clusters kept (~30 MB worst case). Once full, no new clusters are formed (the
    /// extra mark isn't attached). Resetting instead would make cells already on screen or in
    /// scrollback show different text, which output could use to rewrite what was displayed.
    public static let maxClusters = 1 << 18

    public func intern(_ scalars: [UInt32]) -> UInt32? {
        if let i = index[scalars] { return i }
        guard clusters.count < GraphemeTable.maxClusters else { return nil }
        let i = UInt32(clusters.count)
        clusters.append(scalars)
        index[scalars] = i
        return i
    }

    @inlinable public func scalars(_ i: UInt32) -> [UInt32] {
        Int(i) < clusters.count ? clusters[Int(i)] : [0xFFFD]
    }

    /// (existing cluster or single base scalar, appended scalar) -> cluster id. Text with combining
    /// marks or joiners repeats the same combinations constantly; this avoids building and hashing
    /// an array for each one.
    private var extendCache: [UInt64: UInt32] = [:]

    /// The cluster formed by appending `cp` to an existing cluster (`cluster`) or to a single base
    /// scalar. Returns nil if the cluster would exceed the length limit.
    public func extend(_ cluster: UInt32?, base: UInt32, with cp: UInt32) -> UInt32? {
        // Key: 1 bit "is cluster", 31 bits cluster id or base scalar, 32 bits appended scalar.
        let key = (cluster.map { UInt64($0) | 1 << 31 } ?? UInt64(base)) << 32 | UInt64(cp)
        if let id = extendCache[key] { return id }
        var scalars = cluster.map { self.scalars($0) } ?? [base]
        guard scalars.count < 32 else { return nil }
        scalars.append(cp)
        guard let id = intern(scalars) else { return nil }
        if extendCache.count > 1 << 16 { extendCache.removeAll() }
        extendCache[key] = id
        return id
    }
}

/// Per-cell extras that don't fit in the 16-byte cell: underline color and hyperlink.
public struct CellExtra: Hashable {
    public var underlineColor: TermColor
    public var hyperlink: UInt32
}

public final class ExtrasTable {
    public private(set) var entries: [CellExtra] = [CellExtra(underlineColor: .default, hyperlink: 0)]
    private var index: [CellExtra: UInt16] = [:]
    public init() {}

    public func intern(_ e: CellExtra) -> UInt16 {
        if e.underlineColor.isDefault && e.hyperlink == 0 { return 0 }
        if let i = index[e] { return i }
        if entries.count >= Int(UInt16.max) { return 0 }
        let i = UInt16(entries.count)
        entries.append(e)
        index[e] = i
        return i
    }

    @inlinable public subscript(i: UInt16) -> CellExtra { entries[Int(i)] }
}

/// OSC 8 hyperlinks.
public final class HyperlinkTable {
    public struct Link: Hashable { public var id: String; public var uri: String }
    public private(set) var links: [Link] = [Link(id: "", uri: "")]
    private var index: [Link: UInt32] = [:]
    public init() {}

    /// URIs longer than this are ignored (as VTE does), and the table stops growing at `maxLinks`.
    /// When full, new links are dropped rather than reusing ids: reusing would point old cells at
    /// a different URI.
    public static let maxURILength = 2083
    public static let maxIDLength = 256
    public static let maxLinks = 1 << 16

    public func intern(id: String, uri: String) -> UInt32 {
        guard uri.utf8.count <= HyperlinkTable.maxURILength, id.utf8.count <= HyperlinkTable.maxIDLength else { return 0 }
        let l = Link(id: id, uri: uri)
        if let i = index[l] { return i }
        guard links.count < HyperlinkTable.maxLinks else { return 0 }
        let i = UInt32(links.count)
        links.append(l)
        index[l] = i
        return i
    }

    public func uri(_ i: UInt32) -> String? { i > 0 && Int(i) < links.count ? links[Int(i)].uri : nil }
}

public enum CursorShape: Sendable { case block, underline, bar }

public enum MouseTracking: Sendable { case none, x10, normal, button, any }
public enum MouseEncoding: Sendable { case x10, utf8, sgr, sgrPixels }

/// Events produced by the terminal that the UI must act on. Drained on the main thread.
public enum TerminalEvent: Sendable {
    case title(String)
    case bell
    case workingDirectory(String)
    case clipboardWrite(String)
    case clipboardRead
    case notification(title: String, body: String)
    case colorsChanged
    case cursorShapeChanged
    case progress(state: Int, value: Int)
}

extension Array where Element == UInt8 {
    @inlinable mutating func append(ascii s: String) { append(contentsOf: s.utf8) }
}
