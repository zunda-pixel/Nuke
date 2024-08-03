// The MIT License (MIT)
//
// Copyright (c) 2015-2024 Alexander Grebenyuk (github.com/kean).

import Foundation
@preconcurrency import Combine

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
import AppKit
#endif

/// A task performed by the ``ImagePipeline``.
///
/// The pipeline maintains a strong reference to the task until the request
/// finishes or fails; you do not need to maintain a reference to the task unless
/// it is useful for your app.
@ImagePipelineActor
public final class ImageTask: Hashable {
    /// An identifier that uniquely identifies the task within a given pipeline.
    /// Unique only within that pipeline.
    public nonisolated let taskId: Int64

    /// The original request that the task was created with.
    public nonisolated let request: ImageRequest

    /// The priority of the task. The priority can be updated dynamically even
    /// for a task that is already running.
    public nonisolated var priority: ImageRequest.Priority {
        get { nonisolatedState.withLock { $0.priority } }
        set { setPriority(newValue) }
    }

    /// Returns the current download progress. Returns zeros before the download
    /// is started and the expected size of the resource is known.
    public nonisolated var currentProgress: Progress {
        nonisolatedState.withLock { $0.progress }
    }

    /// The download progress.
    public struct Progress: Hashable, Sendable {
        /// The number of bytes that the task has received.
        public let completed: Int64
        /// A best-guess upper bound on the number of bytes of the resource.
        public let total: Int64

        /// Returns the fraction of the completion.
        public var fraction: Float {
            guard total > 0 else { return 0 }
            return min(1, Float(completed) / Float(total))
        }

        /// Initializes progress with the given status.
        public init(completed: Int64, total: Int64) {
            (self.completed, self.total) = (completed, total)
        }
    }

    /// The current state of the task.
    public nonisolated var state: State {
        nonisolatedState.withLock { $0.state }
    }

    /// The state of the image task.
    public enum State {
        /// The task is currently running.
        case running
        /// The task has received a cancel message.
        case cancelled
        /// The task has completed (without being canceled).
        case completed
    }

    // MARK: - Async/Await

    /// Returns the response image.
    public var image: PlatformImage {
        get async throws {
            try await response.image
        }
    }

    /// Returns the image response.
    public var response: ImageResponse {
        get async throws {
            try await withTaskCancellationHandler {
                try await _task.value
            } onCancel: {
                cancel()
            }
        }
    }

    /// The stream of progress updates.
    public nonisolated var progress: AsyncStream<Progress> {
        makeStream {
            if case .progress(let value) = $0 { return value }
            return nil
        }
    }

    /// The stream of image previews generated for images that support
    /// progressive decoding.
    ///
    /// - seealso: ``ImagePipeline/Configuration-swift.struct/isProgressiveDecodingEnabled``
    public nonisolated var previews: AsyncStream<ImageResponse> {
        makeStream {
            if case .preview(let value) = $0 { return value }
            return nil
        }
    }

    // MARK: - Events

    /// The events sent by the pipeline during the task execution.
    public nonisolated var events: AsyncStream<Event> { makeStream { $0 } }

    /// An event produced during the runetime of the task.
    public enum Event: Sendable {
        /// The download progress was updated.
        case progress(Progress)
        /// The pipeline generated a progressive scan of the image.
        case preview(ImageResponse)
        /// The task was cancelled.
        ///
        /// - note: You are guaranteed to receive either `.cancelled` or
        /// `.finished`, but never both.
        case cancelled
        /// The task finish with the given response.
        case finished(Result<ImageResponse, ImagePipeline.Error>)
    }

    private nonisolated let nonisolatedState: Mutex<ImageTaskNonisolatedState>
    private let isDataTask: Bool
    private let onEvent: ((Event, ImageTask) -> Void)?
    private weak var pipeline: ImagePipeline?

    private var _task: Task<ImageResponse, Error>!
    var _continuation: UnsafeContinuation<ImageResponse, Error>?
    var _state: State = .running
    private var _events: PassthroughSubject<Event, Never>?

    nonisolated init(taskId: Int64, request: ImageRequest, isDataTask: Bool, pipeline: ImagePipeline, onEvent: ((Event, ImageTask) -> Void)?) {
        self.taskId = taskId
        self.request = request
        self.nonisolatedState = Mutex(ImageTaskNonisolatedState(priority: request.priority))
        self.isDataTask = isDataTask
        self.pipeline = pipeline
        self.onEvent = onEvent
        self._task = Task { @ImagePipelineActor in
            try await withUnsafeThrowingContinuation { continuation in
                self._continuation = continuation
                pipeline.startImageTask(self, isDataTask: isDataTask)
            }
        }
    }

    /// Marks task as being cancelled.
    ///
    /// The pipeline will immediately cancel any work associated with a task
    /// unless there is an equivalent outstanding task running.
    public nonisolated func cancel() {
        let didChange: Bool = nonisolatedState.withLock {
            guard $0.state == .running else { return false }
            $0.state = .cancelled
            return true
        }
        guard didChange else { return } // Make sure it gets called once (expensive)
        Task {
            await pipeline?.imageTaskCancelCalled(self)
        }
    }

    private nonisolated func setPriority(_ newValue: ImageRequest.Priority) {
        let didChange: Bool = nonisolatedState.withLock {
            guard $0.priority != newValue else { return false }
            $0.priority = newValue
            return $0.state == .running
        }
        guard didChange else { return }
        Task {
            await pipeline?.imageTaskUpdatePriorityCalled(self, priority: newValue)
        }
    }

    // MARK: Internals

    /// Gets called when the task is cancelled either by the user or by an
    /// external event such as session invalidation.
    func _cancel() {
        guard _setState(.cancelled) else { return }
        _dispatch(.cancelled)
    }

    /// Gets called when the associated task sends a new event.
    func _process(_ event: AsyncTask<ImageResponse, ImagePipeline.Error>.Event) {
        switch event {
        case let .value(response, isCompleted):
            if isCompleted {
                _finish(.success(response))
            } else {
                _dispatch(.preview(response))
            }
        case let .progress(value):
            nonisolatedState.withLock { $0.progress = value }
            _dispatch(.progress(value))
        case let .error(error):
            _finish(.failure(error))
        }
    }

    private func _finish(_ result: Result<ImageResponse, ImagePipeline.Error>) {
        guard _setState(.completed) else { return }
        _dispatch(.finished(result))
    }

    func _setState(_ state: State) -> Bool {
        guard _state == .running else { return false }
        _state = state
        if onEvent == nil {
            nonisolatedState.withLock { $0.state = state }
        }
        return true
    }

    /// Dispatches the given event to the observers.
    ///
    /// - warning: The task needs to be fully wired (`_continuation` present)
    /// before it can start sending the events.
    func _dispatch(_ event: Event) {
        guard _continuation != nil else {
            return // Task isn't fully wired yet
        }
        _events?.send(event)
        switch event {
        case .cancelled:
            _events?.send(completion: .finished)
            _continuation?.resume(throwing: CancellationError())
        case .finished(let result):
            let result = result.mapError { $0 as Error }
            _events?.send(completion: .finished)
            _continuation?.resume(with: result)
        default:
            break
        }

        onEvent?(event, self)
        pipeline?.imageTask(self, didProcessEvent: event, isDataTask: isDataTask)
    }

    // MARK: Hashable

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self).hashValue)
    }

    public static nonisolated func == (lhs: ImageTask, rhs: ImageTask) -> Bool {
        ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }
}

// MARK: - ImageTask (Private)

extension ImageTask {
    private nonisolated func makeStream<T>(of closure: @Sendable @escaping (Event) -> T?) -> AsyncStream<T> {
        AsyncStream { continuation in
            Task { @ImagePipelineActor in
                guard let events = self._makeEventsSubject() else {
                    return continuation.finish()
                }
                let cancellable = events.sink { _ in
                    continuation.finish()
                } receiveValue: { event in
                    if let value = closure(event) {
                        continuation.yield(value)
                    }
                    switch event {
                    case .cancelled, .finished:
                        continuation.finish()
                    default:
                        break
                    }
                }
                continuation.onTermination = { _ in
                    cancellable.cancel()
                }
            }
        }
    }

    private func _makeEventsSubject() -> PassthroughSubject<Event, Never>? {
        guard _state == .running else {
            return nil
        }
        if _events == nil {
            _events = PassthroughSubject()
        }
        return _events!
    }
}

private struct ImageTaskNonisolatedState {
    var state: ImageTask.State = .running
    var priority: ImageRequest.Priority
    var progress = ImageTask.Progress(completed: 0, total: 0)
}
