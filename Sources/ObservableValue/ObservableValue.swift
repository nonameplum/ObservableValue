import Foundation

// MARK: - Protocols

/// A read-only observable value that exposes the current snapshot and a concrete stream of changes.
///
/// Use ``BackportObservableValue`` on toolchains or deployment targets where
/// `AsyncSequence.Failure` is unavailable (pre-iOS 18). For modern platforms,
/// prefer ``ObservableValue`` which uses opaque return types.
///
/// ## Overview
///
/// Conforming types provide:
/// - A synchronous ``value`` property for immediate reads.
/// - A ``backportValues`` async sequence that yields each new value to multiple consumers.
///
/// ```swift
/// let state: some BackportObservableValue<Int> = ObservedValue(0)
/// for await value in state.backportValues {
///     print(value)
/// }
/// ```
///
/// - SeeAlso: ``ObservableValue``, ``ObservedValue``
public protocol BackportObservableValue<Value>: Sendable {
  associatedtype Value: Sendable

  /// The current value. Always returns the latest snapshot.
  var value: Value { get }

  /// A concrete, non-throwing async sequence of value changes.
  ///
  /// Each iterator maintains an independent cursor; multiple consumers
  /// may iterate concurrently without interference.
  var backportValues: AsyncStateStream<Value> { get }
}

/// A read-only observable value that exposes the current snapshot and an opaque async sequence of changes.
///
/// Available on iOS 18+, macOS 15+, and other platforms where `AsyncSequence.Failure` exists.
///
/// ## Overview
///
/// ```swift
/// let state: some ObservableValue<Int> = ObservedValue(0)
/// for await value in state.values {
///     print(value)
/// }
/// ```
///
/// - SeeAlso: ``BackportObservableValue``, ``ObservedValue``
@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
public protocol ObservableValue<Value>: Sendable {
  associatedtype Value: Sendable
  associatedtype Sequence: AsyncSequence
  where Sequence.Element == Value, Sequence.Failure == Never, Sequence: Sendable

  /// The current value. Always returns the latest snapshot.
  var value: Value { get }

  /// An opaque, non-throwing async sequence of value changes.
  var values: Sequence { get }
}

/// A mutable observable value that supports atomic in-place updates.
///
/// - SeeAlso: ``BackportMutableObservableValue``, ``ObservedValue``
@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
public protocol MutableObservableValue<Value>: ObservableValue {
  /// Atomically mutates the wrapped value and returns the result of `body`.
  ///
  /// - Parameter body: A closure that receives an `inout` reference to the current value.
  /// - Returns: The value returned by `body`.
  /// - Throws: Rethrows any error thrown by `body`. Mutations are preserved even on throw.
  func update<R, E: Error>(_ body: (inout sending Value) throws(E) -> R) throws(E) -> sending R
}

/// A backportable mutable observable value that supports atomic in-place updates.
///
/// - SeeAlso: ``MutableObservableValue``, ``ObservedValue``
public protocol BackportMutableObservableValue<Value>: BackportObservableValue {
  /// Atomically mutates the wrapped value and returns the result of `body`.
  ///
  /// - Parameter body: A closure that receives an `inout` reference to the current value.
  /// - Returns: The value returned by `body`.
  /// - Throws: Rethrows any error thrown by `body`. Mutations are preserved even on throw.
  func update<R, E: Error>(_ body: (inout sending Value) throws(E) -> R) throws(E) -> R
}

// MARK: - ObservedValue

/// A thread-safe container that holds a current value and broadcasts changes to multiple async consumers.
///
/// `ObservedValue` is the primary concrete type in this package. It provides:
/// - A synchronous ``value`` property for immediate reads.
/// - An ``update(_:)`` method for atomic mutations.
/// - A ``values`` async sequence that delivers changes to any number of concurrent consumers.
///
/// ## Overview
///
/// ```swift
/// let counter = ObservedValue(0)
///
/// // Multiple consumers, each with an independent cursor
/// Task { for await v in counter.values { print("A:", v) } }
/// Task { for await v in counter.values { print("B:", v) } }
///
/// // Atomic mutation
/// counter.update { $0 += 1 }
///
/// // Synchronous read
/// print(counter.value)  // 1
/// ```
///
/// ## Backpressure
///
/// Producers are **never** blocked. Each consumer sees the latest value when it resumes;
/// intermediate values may be skipped if the consumer is slower than the producer.
/// This is analogous to Combine's `CurrentValueSubject`.
///
/// ## Thread Safety
///
/// All operations are internally synchronized. The type is `Sendable` and safe to use
/// from any isolation domain.
///
/// - SeeAlso: ``AsyncStateStream``, ``BackportObservableValue``, ``ObservableValue``
public final class ObservedValue<Value: Sendable>: @unchecked Sendable, BackportMutableObservableValue {
  private let allocation: CurrentValueAllocation<Value>

  /// Creates an observable value with the given initial value.
  ///
  /// - Parameter value: The initial value.
  public init(_ value: sending Value) {
    allocation = .init(state: CurrentValueState(value: value))
  }

  /// The current value.
  ///
  /// This property is read-only to prevent race conditions. Use ``update(_:)``
  /// for mutations. For example, `value += 1` would require two lock acquisitions
  /// (read then write), creating a race window.
  public var value: Value {
    allocation.mutex.withLock { $0.value }
  }

  /// Atomically mutates the wrapped value and returns the result of `body`.
  ///
  /// The mutation is performed while holding an internal lock. After `body` returns
  /// (or throws), all waiting consumers are resumed with the new value.
  ///
  /// - Parameter body: A closure that receives an `inout` reference to the current value.
  /// - Returns: The value returned by `body`.
  /// - Throws: Rethrows any error thrown by `body`. Mutations are preserved even on throw.
  ///
  /// ```swift
  /// let result = state.update { value -> String in
  ///     value += 1
  ///     return "incremented to \(value)"
  /// }
  /// ```
  @discardableResult
  public func update<R, E: Error>(_ body: (inout sending Value) throws(E) -> R) throws(E) -> sending R {
    func lockBody(state: inout CurrentValueState<Value>) throws(E) -> sending R {
      var wrappedValue = state.value
      do {
        let result = try body(&wrappedValue)
        state.value = wrappedValue
        return result
      } catch {
        state.value = wrappedValue
        throw error
      }
    }
    return try allocation.mutex.withLock(lockBody)
  }

  /// An async sequence of value changes.
  ///
  /// Each call to `makeAsyncIterator()` creates an independent cursor.
  /// The first value yielded is always the current snapshot at iteration start.
  public var values: AsyncStateStream<Value> {
    AsyncStateStream(allocation: allocation)
  }
}

extension ObservedValue: BackportObservableValue {
  public var backportValues: AsyncStateStream<Value> { values }
}

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension ObservedValue: ObservableValue where Value: Sendable {
  public typealias Sequence = AsyncStateStream<Value>
}

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension ObservedValue: MutableObservableValue {}

// MARK: - AsyncStateStream

/// A non-throwing async sequence that yields the latest value from an ``ObservedValue``.
///
/// Each iterator maintains an independent cursor, allowing multiple concurrent consumers.
/// Iterators always receive the current value on first call to `next()`, then suspend
/// until the value changes.
///
/// ## Overview
///
/// ```swift
/// let state = ObservedValue("idle")
///
/// Task {
///     for await value in state.values {
///         print("observer 1:", value)
///     }
/// }
///
/// Task {
///     for await value in state.values {
///         print("observer 2:", value)
///     }
/// }
/// ```
///
/// ## Backpressure
///
/// Producers are never blocked. If a consumer is slow, it receives the latest value
/// when it resumes—intermediate values may be skipped.
///
/// ## Termination
///
/// The sequence terminates (yields `nil`) when:
/// - The owning ``ObservedValue`` is deallocated.
/// - The consuming task is cancelled.
///
/// - SeeAlso: ``ObservedValue``
public struct AsyncStateStream<Value: Sendable>: AsyncSequence, Sendable {
  public typealias Element = Value
  public typealias Failure = Never

  /// An iterator that suspends until the next value change.
  ///
  /// - Important: Iterators are **not** `Sendable`. Do not share an iterator across tasks.
  public struct AsyncIterator: AsyncIteratorProtocol {
    /// Returns the next value, or `nil` if the sequence terminated.
    ///
    /// On first call, returns the current snapshot. Subsequent calls suspend
    /// until the value changes, the source is deallocated, or the task is cancelled.
    public mutating func next() async -> Element? {
      await next(isolation: nil)
    }

    public mutating func next(isolation _: isolated (any Actor)?) async throws(Failure) -> Value? {
      guard let allocation else {
        return nil
      }
      let uuid = UUID()
      let generationAndResult = await withTaskCancellationHandler {
        await withCheckedContinuation {
          (continuation: CheckedContinuation<(Int, Value)?, Never>) in
          allocation.mutex.withLock {
            if Task.isCancelled {
              continuation.resume(returning: nil)
            } else if $0.generation > generation {
              continuation.resume(returning: ($0.generation, $0.value))
            } else {
              $0.pendingContinuations.append((uuid, continuation))
            }
          }
        }
      } onCancel: {
        allocation.mutex.withLock {
          if let index = $0.pendingContinuations.firstIndex(where: { $0.0 == uuid }) {
            $0.pendingContinuations.remove(at: index).1.resume(returning: nil)
          }
        }
      }
      guard let generationAndResult else {
        return nil
      }
      generation = generationAndResult.0
      return generationAndResult.1
    }

    fileprivate weak var allocation: CurrentValueAllocation<Value>?
    var generation = 0
  }

  /// Creates a new iterator with an independent cursor.
  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(allocation: allocation)
  }

  fileprivate weak var allocation: CurrentValueAllocation<Value>?
}

private struct CurrentValueState<Value: Sendable> {
  // iterators start with generation = 0, so our initial value
  // has generation 1, so that even that will be delivered.
  var generation = 1
  var value: Value {
    didSet {
      generation += 1
      for (_, continuation) in pendingContinuations {
        continuation.resume(returning: (generation, value))
      }
      pendingContinuations = []
    }
  }

  var pendingContinuations: [(UUID, CheckedContinuation<(Int, Value)?, Never>)] = []
}

private final class CurrentValueAllocation<Wrapped: Sendable>: Sendable {
  let mutex: Mutex<CurrentValueState<Wrapped>>

  init(state: sending CurrentValueState<Wrapped>) {
    mutex = Mutex(state)
  }

  deinit {
    let continuations = mutex.withLock { state -> [CheckedContinuation<(Int, Wrapped)?, Never>] in
      defer { state.pendingContinuations.removeAll() }
      return state.pendingContinuations.map(\.1)
    }
    for continuation in continuations {
      continuation.resume(returning: nil)
    }
  }
}
