# ObservableValue

<p align="center">
  <img src="resources/ObservableValue_logo.png" alt="ObservableValue Logo" width="200"/>
</p>

Current-value semantics for Swift concurrency: a multi-consumer async sequence that always yields the latest value—like Combine's `CurrentValueSubject`, but for async/await.

## Overview

Swift's structured concurrency lacks a built-in "current value" primitive. `ObservableValue` fills that gap:

| Need | Solution |
|------|----------|
| Synchronous snapshot | `value` property |
| Async stream of changes | `values` / `backportValues` |
| Multiple concurrent consumers | Each iterator is independent |
| No backpressure on producer | Writes never block |

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/nonameplum/ObservableValue", from: "1.0.0")
]
```

Or in Xcode: **File → Add Package Dependencies** → paste the URL above.

## Quick Start

```swift
import ObservableValue

let counter = ObservedValue(0)

// Consume updates from multiple tasks
Task {
    for await value in counter.values {
        print("seen:", value)
    }
}

// Atomic mutation
counter.update { $0 += 1 }

// Synchronous read
print("current:", counter.value)  // 1
```

### Backport API

On toolchains where `AsyncSequence.Failure` isn't available, use the concrete stream:

```swift
for await value in counter.backportValues {
    print("value:", value)
}
```

## Semantics

**No backpressure.** Producers proceed immediately; consumers get the *latest* value when they resume. Intermediate values may be skipped if a consumer is slower than the producer.

```swift
let state = ObservedValue(0)
var iterator = state.values.makeAsyncIterator()

state.update { $0 = 1 }
state.update { $0 = 2 }
state.update { $0 = 3 }

let observed = await iterator.next()  // 3 (skipped 1, 2)
```

**Multi-consumer.** Each iterator maintains its own cursor:

```swift
Task { for await v in state.values { print("A:", v) } }
Task { for await v in state.values { print("B:", v) } }
```

**Throwing updates.** The `update` closure can throw; mutations are preserved even on error:

```swift
do {
    try state.update { value in
        value = 10
        throw SomeError()
    }
} catch {
    print(state.value)  // 10
}
```

## Comparison

| Feature | `ObservedValue` | `CurrentValueSubject` | `AsyncChannel` |
|---------|-----------------|----------------------|----------------|
| Synchronous read | ✓ | ✓ | ✗ |
| Multi-consumer | ✓ | ✓ | ✓ |
| Backpressure | ✗ (latest wins) | ✗ | ✓ |
| Async/await native | ✓ | ✗ | ✓ |
| iOS 16+ compatible | ✓ | ✓ | ✓ |

## Documentation

Full API documentation is available at:
- [ObservableValue Documentation](https://nonameplum.github.io/ObservableValue/main/documentation/observablevalue/)

## Requirements

- Swift 6.0+
- iOS 16.0+ / macOS 13.0+ / tvOS 16.0+ / watchOS 9.0+ / visionOS 1.0+

## Credits

Inspired by Combine's [`CurrentValueSubject`](https://developer.apple.com/documentation/combine/currentvaluesubject) and the [swift-async-algorithms](https://github.com/apple/swift-async-algorithms) package.

## License

MIT. See [LICENSE](LICENSE).

