import Foundation

/// The render state of a cache-backed surface (a screener tab, the Markets list, the
/// regime banner). The disk-backed stores can't tell SwiftUI apart "never loaded yet"
/// from "loaded and genuinely empty" on their own — on a cold launch with no cache the
/// store is empty *and* the sweep hasn't ticked, so a naive `rows.isEmpty` check flashes
/// a false "No matches". This enum makes the distinction explicit: a missing snapshot /
/// no-completed-sweep is `.loading`, and `.empty` is reserved for a finished sweep that
/// produced nothing.
enum LoadState: Equatable {
    /// No data yet — cache miss with a sweep pending or in progress.
    case loading
    /// A sweep completed and produced no rows.
    case empty
    /// The sweep failed before any data landed; carries the message to show.
    case failed(String)
    /// Data is present and renderable.
    case ready
}
