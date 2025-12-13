import Foundation
import Testing

@testable import ObservableValue

@Suite
struct ObservableValueTests {
  @Test("delivers initial value and subsequent updates to a single consumer")
  func test_single_consumer_sees_initial_and_updates() async throws {
    let state = ObservedValue(0)
    var iterator = state.values.makeAsyncIterator()

    let first = try #require(await iterator.next())
    #expect(first == 0)

    state.update { $0 += 1 }
    let second = try #require(await iterator.next())
    #expect(second == 1)
  }

  @Test("multiple consumers each see the stream independently")
  func test_multiple_consumers_receive_updates() async {
    let state = ObservedValue(0)

    var iterator1 = state.values.makeAsyncIterator()
    var iterator2 = state.values.makeAsyncIterator()

    // Initial value delivered to both.
    let first1 = await iterator1.next()
    let first2 = await iterator2.next()
    #expect(first1 == 0)
    #expect(first2 == 0)

    state.update { $0 = 1 }
    let v1a = await iterator1.next()
    let v2a = await iterator2.next()
    #expect(v1a == 1)
    #expect(v2a == 1)

    state.update { $0 = 2 }
    let v1b = await iterator1.next()
    let v2b = await iterator2.next()
    #expect(v1b == 2)
    #expect(v2b == 2)

    state.update { $0 = 3 }
    let v1c = await iterator1.next()
    let v2c = await iterator2.next()
    #expect(v1c == 3)
    #expect(v2c == 3)
  }

  @Test("multiple detached consumers receive all values via gated handshake")
  func test_multiple_detached_consumers_receive_updates() async {
    let state = ObservedValue(0)
    let valuesToProduce = [1, 2, 3]

    // Handshake gates (reusable each round)
    let consumed1 = Gate()
    let consumed2 = Gate()
    let nextReady1 = Gate()
    let nextReady2 = Gate()

    func makeConsumer(
      consumed: Gate,
      nextReady: Gate
    ) -> Task<[Int], Never> {
      Task.detached { @Sendable [state] in
        var results = [Int]()
        var iterator = state.values.makeAsyncIterator()

        for round in 0...valuesToProduce.count {
          if let value = await iterator.next() {
            results.append(value)
          }
          // Signal consumption and wait for next (except final round)
          if round < valuesToProduce.count {
            consumed.open()
            await nextReady.enter()
          }
        }
        return results
      }
    }

    let consumer1 = makeConsumer(consumed: consumed1, nextReady: nextReady1)
    let consumer2 = makeConsumer(consumed: consumed2, nextReady: nextReady2)

    // Orchestrate: wait for both consumers, produce next value, release them
    for value in valuesToProduce {
      await consumed1.enter()
      await consumed2.enter()

      state.update { $0 = value }

      nextReady1.open()
      nextReady2.open()
    }

    let results1 = await consumer1.value
    let results2 = await consumer2.value

    #expect(results1 == [0, 1, 2, 3])
    #expect(results2 == [0, 1, 2, 3])
  }

  @Test("sequential consumers each start with current value")
  func test_sequential_consumers() async throws {
    let state = ObservedValue(0)

    // First consumer reads initial value then updates
    var iterator1 = state.values.makeAsyncIterator()
    let v1 = try #require(await iterator1.next())
    #expect(v1 == 0)

    state.update { $0 = 1 }
    let v2 = try #require(await iterator1.next())
    #expect(v2 == 1)

    state.update { $0 = 2 }
    let v3 = try #require(await iterator1.next())
    #expect(v3 == 2)

    // Second consumer starts after first finished; sees current value (not exhausted)
    var iterator2 = state.values.makeAsyncIterator()
    let v4 = try #require(await iterator2.next())
    #expect(v4 == 2)

    state.update { $0 = 3 }
    let v5 = try #require(await iterator2.next())
    #expect(v5 == 3)
  }

  @Test("slow consumer observes only the latest value after a burst of updates")
  func test_slow_consumer_gets_latest_snapshot() async throws {
    let state = ObservedValue(0)
    var iterator = state.values.makeAsyncIterator()

    state.update { $0 = 1 }
    state.update { $0 = 2 }
    state.update { $0 = 3 }

    let observed = try #require(await iterator.next())
    #expect(observed == 3)
  }

  @Test("cancellation resumes a pending iterator with nil")
  func test_cancellation_resumes_nil() async {
    let state = ObservedValue(0)
    var iterator = state.values.makeAsyncIterator()

    let task = Task { await iterator.next() }
    task.cancel()

    let value = await task.value
    #expect(value == nil)
  }

  @Test("deinit resumes pending continuations with nil")
  func test_deinit_resumes_waiters() async {
    var state: ObservedValue<Int>? = ObservedValue(0)
    var iterator = state!.values.makeAsyncIterator()

    let waiter = Task { await iterator.next() }
    state = nil

    let value = await waiter.value
    #expect(value == nil)
  }

  @Test("update propagates thrown errors after applying inout mutations")
  func test_update_persists_mutations_on_throw() async {
    enum SampleError: Error { case boom }

    let state = ObservedValue(1)
    do {
      _ = try state.update { value -> Int in
        value = 5
        throw SampleError.boom
      }
      Issue.record("update should have thrown")
    } catch {
      #expect(state.value == 5)
    }
  }

  @Test("producer is not backpressured by slow consumers")
  func test_producer_not_backpressured() async {
    let state = ObservedValue(0)

    let slowConsumer = Task {
      var iterator = state.values.makeAsyncIterator()
      try? await Task.sleep(for: .milliseconds(50))
      _ = await iterator.next()
    }

    let clock = ContinuousClock()
    let duration = clock.measure {
      for i in 1...2000 {
        state.update { $0 = i }
      }
    }

    await slowConsumer.value
    #expect(duration < .milliseconds(20))
    #expect(state.value == 2000)
  }

  @Test("update returns the result of the closure")
  func test_update_returns_result() {
    let state = ObservedValue(10)

    let result = state.update { value -> String in
      value += 5
      return "new value: \(value)"
    }

    #expect(result == "new value: 15")
    #expect(state.value == 15)
  }

  @Test("backportValues provides the same stream as values")
  func test_backport_values() async throws {
    let state = ObservedValue("hello")
    var iterator = state.backportValues.makeAsyncIterator()

    let first = try #require(await iterator.next())
    #expect(first == "hello")

    state.update { $0 = "world" }
    let second = try #require(await iterator.next())
    #expect(second == "world")
  }

  @Test("iterator returns nil repeatedly after source is deallocated")
  func test_iterator_returns_nil_after_dealloc() async {
    var state: ObservedValue<Int>? = ObservedValue(42)
    var iterator = state!.values.makeAsyncIterator()

    // Consume initial value
    let first = await iterator.next()
    #expect(first == 42)

    // Deallocate source
    state = nil

    // Subsequent calls should return nil
    let second = await iterator.next()
    let third = await iterator.next()
    #expect(second == nil)
    #expect(third == nil)
  }

  @Test("update with unchanged value still triggers observers")
  func test_update_same_value_triggers_observers() async throws {
    let state = ObservedValue(5)
    var iterator = state.values.makeAsyncIterator()

    // Consume initial value
    let first = try #require(await iterator.next())
    #expect(first == 5)

    // Update to same value
    state.update { $0 = 5 }

    // Observer should still receive the "new" value
    let second = try #require(await iterator.next())
    #expect(second == 5)
  }

  @Test("concurrent updates from multiple tasks are serialized")
  func test_concurrent_updates_serialized() async {
    let state = ObservedValue(0)
    let iterations = 1000

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<10 {
        group.addTask {
          for _ in 0..<iterations {
            state.update { $0 += 1 }
          }
        }
      }
    }

    #expect(state.value == 10 * iterations)
  }

  @Test("works with reference type wrapped values")
  func test_reference_type_wrapped_value() async throws {
    final class Counter: Sendable {
      let value: Int
      init(_ value: Int) { self.value = value }
    }

    let state = ObservedValue(Counter(0))
    var iterator = state.values.makeAsyncIterator()

    let first = try #require(await iterator.next())
    #expect(first.value == 0)

    state.update { $0 = Counter(42) }
    let second = try #require(await iterator.next())
    #expect(second.value == 42)
  }

  @Test("conforms to expected protocols")
  func test_protocol_conformance() {
    func assertBackportMutable<T: BackportMutableObservableValue>(_: T) {}
    func assertBackport<T: BackportObservableValue>(_: T) {}

    let state = ObservedValue(0)
    assertBackportMutable(state)
    assertBackport(state)
  }

  @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
  @Test("conforms to modern protocols on iOS 18+")
  func test_modern_protocol_conformance() {
    func assertMutable<T: MutableObservableValue>(_: T) {}
    func assertObservable<T: ObservableValue>(_: T) {}

    let state = ObservedValue(0)
    assertMutable(state)
    assertObservable(state)
  }
}

private final class Gate: Sendable {
  private enum State {
    case closed
    case open
    case pending(UnsafeContinuation<Void, Never>)
  }

  private let state = Mutex(State.closed)

  func open() {
    state.withLock { state -> UnsafeContinuation<Void, Never>? in
      switch state {
      case .closed:
        state = .open
        return nil
      case .open:
        return nil
      case .pending(let continuation):
        state = .closed
        return continuation
      }
    }?.resume()
  }

  func enter() async {
    var other: UnsafeContinuation<Void, Never>?
    await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
      state.withLock { state -> UnsafeContinuation<Void, Never>? in
        switch state {
        case .closed:
          state = .pending(continuation)
          return nil
        case .open:
          state = .closed
          return continuation
        case .pending(let existing):
          other = existing
          state = .pending(continuation)
          return nil
        }
      }?.resume()
    }
    other?.resume()
  }
}
