import Fluent
import Queues
import Vapor

struct ExtractionPayload: Codable, Sendable {
    let labResultID: UUID
}

/// Background job: extract one uploaded file into structured data. Enqueued at
/// upload time; run by the worker process (see R-Flow/System-Flow).
struct ExtractionJob: AsyncJob {
    typealias Payload = ExtractionPayload

    func dequeue(_ context: QueueContext, _ payload: ExtractionPayload) async throws {
        let app = context.application

        guard let apiKey = Environment.get("LLM_API_KEY") else {
            throw LLMError.notConfigured
        }
        guard let labResult = try await LabResult.find(payload.labResultID, on: app.db) else {
            context.logger.warning("ExtractionJob: lab_result \(payload.labResultID) not found; skipping")
            return
        }

        let provider = AnthropicProvider(
            client: app.client,
            apiKey: apiKey,
            modelName: LLMModels.extraction,
            logger: context.logger,
            effort: ExtractionPrompt.effort
        )
        let service = ExtractionService(
            provider: provider,
            db: app.db,
            storage: FileStorage(for: app),
            logger: context.logger
        )
        do {
            try await service.extract(labResult: labResult)
        } catch let error as LLMError where !error.isRetryable {
            // `extract` has already marked the file `failed`. Returning instead
            // of rethrowing skips the queue's retries — each would bill the
            // model again for a guaranteed-identical failure.
            context.logger.error("ExtractionJob: non-retryable failure for \(payload.labResultID): \(error)")
        }
    }

    /// Called after retries are exhausted — mark the file as failed so the
    /// client can surface "couldn't parse, try re-uploading".
    func error(_ context: QueueContext, _ error: any Error, _ payload: ExtractionPayload) async throws {
        context.logger.error("ExtractionJob failed for \(payload.labResultID): \(String(reflecting: error))")
        if let labResult = try? await LabResult.find(payload.labResultID, on: context.application.db) {
            labResult.parseStatus = .failed
            try? await labResult.save(on: context.application.db)
        }
    }
}
