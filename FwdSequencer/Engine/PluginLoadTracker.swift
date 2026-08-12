import Foundation

/// Store-side generation tokens for asynchronous instrument loads. An old completion
/// must never clear the loading state of a newer request for the same track.
nonisolated struct PluginLoadTracker: Equatable {
    private var tokens: [UUID: UUID] = [:]

    var isEmpty: Bool { tokens.isEmpty }

    mutating func begin(for trackID: UUID) -> UUID {
        let token = UUID()
        tokens[trackID] = token
        return token
    }

    mutating func finish(for trackID: UUID, token: UUID) -> Bool {
        guard tokens[trackID] == token else { return false }
        tokens.removeValue(forKey: trackID)
        return true
    }

    mutating func cancel(for trackID: UUID) {
        tokens.removeValue(forKey: trackID)
    }

    mutating func cancelAll() {
        tokens.removeAll()
    }
}
