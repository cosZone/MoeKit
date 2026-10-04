import Foundation
import Observation

@MainActor @Observable
final class ProcessTerminationStore {
    private(set) var review: ProcessStopReview?
    private(set) var acknowledgedReviewID: UUID?
    private(set) var results: [ProcessStopResult] = []
    private(set) var isBusy = false {
        didSet { UpdateInstallationSafety.shared.changed(self) }
    }
    private(set) var isExecuting = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let executor: ProcessTerminationExecutor
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var invalidationTask: Task<Void, Never>?
    @ObservationIgnored private var requestID: UUID?
    @ObservationIgnored private var contextGeneration: UInt64 = 0
    @ObservationIgnored private var mayOfferForce = false

    init(executor: ProcessTerminationExecutor = ProcessTerminationExecutor()) { self.executor = executor }

    var forceCandidates: [ProcessInventoryRecord] {
        guard mayOfferForce else { return [] }
        return results.filter { $0.mode == .graceful && $0.signalSubmitted && $0.presence == .running }.map(\.record)
    }

    func prepare(_ records: [ProcessInventoryRecord], mode: ProcessStopMode) {
        guard !isBusy else { return }
        review = nil; acknowledgedReviewID = nil; errorMessage = nil; isBusy = true
        let id = UUID(); requestID = id
        let invalidation = invalidationTask
        task = Task { [weak self, executor] in
            do {
                await invalidation?.value
                try Task.checkCancellation()
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

    func acknowledge(reviewID: UUID, value: Bool) {
        guard !isBusy, review?.id == reviewID else { return }
        acknowledgedReviewID = value ? reviewID : nil
    }

    /// Acknowledgement is bound to this exact nonce, not transient view state.
    func confirm(reviewID: UUID) {
        guard !isBusy, review?.id == reviewID, acknowledgedReviewID == reviewID else { return }
        review = nil; acknowledgedReviewID = nil; errorMessage = nil
        isBusy = true; isExecuting = true; mayOfferForce = false
        let id = UUID(); requestID = id
        let context = contextGeneration
        task = Task { [weak self, executor] in
            do {
                let results = try await executor.execute(reviewID: reviewID)
                guard let self, self.requestID == id else { return }
                // Cancellation or mode/navigation changes cannot erase a real
                // submitted signal. Views show these outcomes only in real mode.
                self.results = results
                self.mayOfferForce = self.contextGeneration == context && !Task.isCancelled
                self.isBusy = false; self.isExecuting = false; self.task = nil
            } catch {
                guard let self, self.requestID == id else { return }
                self.errorMessage = (error as? ProcessTerminationError)?.errorDescription
                    ?? String(localized: "The stop was cancelled before signal submission.")
                self.isBusy = false; self.isExecuting = false; self.task = nil
            }
        }
    }

    func cancelReview(clearForceEligibility: Bool = false) {
        task?.cancel()
        review = nil; acknowledgedReviewID = nil; errorMessage = nil
        if !isExecuting {
            task = nil; requestID = nil; isBusy = false
        }
        if clearForceEligibility { contextGeneration &+= 1; mayOfferForce = false }
        let previous = invalidationTask
        invalidationTask = Task { [executor] in
            await previous?.value
            await executor.invalidate(clearForceEligibility: clearForceEligibility)
        }
    }

    /// Reset selection authority, not knowledge of an irreversible action.
    func reset() { cancelReview(clearForceEligibility: true) }
}
