import Foundation
import Observation

@MainActor @Observable
final class ProcessTerminationStore {
    private(set) var review: ProcessStopReview?
    private(set) var results: [ProcessStopResult] = []
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let executor: ProcessTerminationExecutor
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var requestID: UUID?

    init(executor: ProcessTerminationExecutor = ProcessTerminationExecutor()) { self.executor = executor }

    var forceCandidates: [ProcessInventoryRecord] {
        results.filter { $0.mode == .graceful && $0.signalSubmitted && $0.presence == .running }.map(\.record)
    }

    func prepare(_ records: [ProcessInventoryRecord], mode: ProcessStopMode) {
        guard !isBusy else { return }
        review = nil; errorMessage = nil; isBusy = true
        let id = UUID(); requestID = id
        task = Task { [weak self, executor] in
            do {
                let review = try await executor.prepare(records: records, mode: mode)
                try Task.checkCancellation()
                guard let self, self.requestID == id else { return }
                self.review = review; self.isBusy = false; self.task = nil
            } catch {
                guard let self, self.requestID == id else { return }
                self.errorMessage = (error as? ProcessTerminationError)?.errorDescription
                    ?? String(localized: "The exact targets could not be prepared. No signal was sent.")
                self.isBusy = false; self.task = nil
            }
        }
    }

    /// Called only by the destructive confirmation button after the user has
    /// acknowledged the displayed consequences. A nonce cannot be reused.
    func confirm(reviewID: UUID) {
        guard !isBusy, review?.id == reviewID else { return }
        review = nil; errorMessage = nil; isBusy = true
        let id = UUID(); requestID = id
        task = Task { [weak self, executor] in
            do {
                let results = try await executor.execute(reviewID: reviewID)
                guard let self, self.requestID == id else { return }
                self.results = results; self.isBusy = false; self.task = nil
            } catch {
                guard let self, self.requestID == id else { return }
                self.errorMessage = (error as? ProcessTerminationError)?.errorDescription
                    ?? String(localized: "The stop was cancelled before signal submission.")
                self.isBusy = false; self.task = nil
            }
        }
    }

    func cancelReview() {
        task?.cancel(); task = nil; requestID = nil
        review = nil; isBusy = false; errorMessage = nil
        Task { [executor] in await executor.invalidate() }
    }

    func reset() { cancelReview(); results = [] }
}
