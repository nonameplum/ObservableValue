# ``ObservableValue``

Current-value semantics for Swift concurrency: a multi-consumer async sequence that always yields the latest value—like Combine's `CurrentValueSubject`, but for async/await.

![ObservableValue logo](ObservableValue_logo)

## Overview

Swift's structured concurrency lacks a built-in "current value" primitive. This package fills that gap with ``ObservedValue``:

- **Synchronous snapshot**: Read ``ObservedValue/value`` at any time.
- **Async stream of changes**: Iterate ``ObservedValue/values`` from multiple tasks.
- **No backpressure**: Producers proceed immediately; slow consumers see the latest value.
- **Backportable**: Works on iOS 16+ with Swift 6 toolchains.

```swift
import ObservableValue

let counter = ObservedValue(0)

// Multiple concurrent consumers
Task { for await v in counter.values { print("A:", v) } }
Task { for await v in counter.values { print("B:", v) } }

// Atomic mutation
counter.update { $0 += 1 }

// Synchronous read
print(counter.value)  // 1
```

### Backpressure Semantics

Producers are never blocked. Each consumer sees the *latest* value when it resumes—intermediate values may be skipped if the consumer is slower than the producer.

```swift
let state = ObservedValue(0)
var iterator = state.values.makeAsyncIterator()

state.update { $0 = 1 }
state.update { $0 = 2 }
state.update { $0 = 3 }

let observed = await iterator.next()  // 3 (skipped 1, 2)
```

### Backport API

On toolchains where `AsyncSequence.Failure` isn't available, use the concrete stream:

```swift
for await value in counter.backportValues {
    print("value:", value)
}
```

## Topics

### Essentials

- ``ObservedValue``
- ``AsyncStateStream``

### Protocols

- ``BackportObservableValue``
- ``BackportMutableObservableValue``
- ``ObservableValue``
- ``MutableObservableValue``