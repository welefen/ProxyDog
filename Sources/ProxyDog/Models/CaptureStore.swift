import Foundation

/// Receives capture events from the proxy core. Implementations are called from
/// arbitrary (NIO event loop) threads, so they must be thread safe.
protocol CaptureSink: AnyObject, Sendable {
    /// Full snapshot of a request. Called on creation and on every update.
    func captureDidUpdate(_ request: CapturedRequest)
}

/// Observable, main-actor bound store of captured traffic.
@MainActor
final class CaptureStore: ObservableObject {
    @Published private(set) var requests: [CapturedRequest] = []
    @Published private(set) var isPaused = false

    /// Maximum number of exchanges kept in memory; older ones fall off the end.
    var capacity: Int = AppDefaults.maxCapturedRequests

    /// While paused new captures are dropped, like Proxyman's pause button.
    func setPaused(_ paused: Bool) {
        isPaused = paused
    }

    func upsert(_ request: CapturedRequest) {
        guard !isPaused else { return }
        if let index = requests.firstIndex(where: { $0.id == request.id }) {
            // Pin state is owned by the store; the proxy core reports everything else.
            var updated = request
            updated.isPinned = requests[index].isPinned
            requests[index] = updated
        } else {
            requests.insert(request, at: 0)
            if requests.count > capacity {
                requests.removeLast(requests.count - capacity)
            }
        }
    }

    /// Replaces the whole buffer in one publish. Used by the QA stress loader so a large
    /// fixture does not pay the per-row prepend cost; live captures still go through `upsert`.
    func loadBatch(_ batch: [CapturedRequest]) {
        requests = Array(batch.prefix(capacity))
    }

    func clear() {
        requests.removeAll()
    }

    func remove(id: CapturedRequest.ID) {
        requests.removeAll { $0.id == id }
    }

    func togglePin(id: CapturedRequest.ID) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        requests[index].isPinned.toggle()
    }

    func request(id: CapturedRequest.ID) -> CapturedRequest? {
        requests.first { $0.id == id }
    }
}

/// Bridges the proxy core's thread-agnostic sink to the main-actor store.
final class MainActorCaptureSink: CaptureSink, @unchecked Sendable {
    private weak var store: CaptureStore?

    init(store: CaptureStore) {
        self.store = store
    }

    func captureDidUpdate(_ request: CapturedRequest) {
        let store = self.store
        Task { @MainActor in
            store?.upsert(request)
        }
    }
}
