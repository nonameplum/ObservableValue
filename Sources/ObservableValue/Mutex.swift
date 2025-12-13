#if compiler(>=6)

#if !canImport(WinSDK)

// Backports the Swift 6 type Mutex<Value> to all Darwin platforms

@available(macOS, deprecated: 15.0, message: "use Mutex from Synchronization module")
@available(iOS, deprecated: 18.0, message: "use Mutex from Synchronization module")
@available(tvOS, deprecated: 18.0, message: "use Mutex from Synchronization module")
@available(watchOS, deprecated: 11.0, message: "use Mutex from Synchronization module")
@available(visionOS, deprecated: 2.0, message: "use Mutex from Synchronization module")
struct Mutex<Value: ~Copyable>: ~Copyable {
  let storage: Storage<Value>

  init(_ initialValue: consuming sending Value) {
    self.storage = Storage(initialValue)
  }

  borrowing func withLock<Result, E: Error>(
    _ body: (inout sending Value) throws(E) -> sending Result
  ) throws(E) -> sending Result {
    storage.lock()
    defer { storage.unlock() }
    return try body(&storage.value)
  }

  borrowing func withLockIfAvailable<Result, E: Error>(
    _ body: (inout sending Value) throws(E) -> sending Result
  ) throws(E) -> sending Result? {
    guard storage.tryLock() else { return nil }
    defer { storage.unlock() }
    return try body(&storage.value)
  }
}

extension Mutex: @unchecked Sendable where Value: ~Copyable {}

#else

// Windows doesn't support ~Copyable yet

struct Mutex<Value>: @unchecked Sendable {
  let storage: Storage<Value>

  init(_ initialValue: consuming sending Value) {
    self.storage = Storage(initialValue)
  }

  borrowing func withLock<Result, E: Error>(
    _ body: (inout sending Value) throws(E) -> sending Result
  ) throws(E) -> sending Result {
    storage.lock()
    defer { storage.unlock() }
    return try body(&storage.value)
  }

  borrowing func withLockIfAvailable<Result, E: Error>(
    _ body: (inout sending Value) throws(E) -> sending Result
  ) throws(E) -> sending Result? {
    guard storage.tryLock() else { return nil }
    defer { storage.unlock() }
    return try body(&storage.value)
  }
}

#endif

#if canImport(Darwin)

import struct os.os_unfair_lock_t
import struct os.os_unfair_lock
import func os.os_unfair_lock_lock
import func os.os_unfair_lock_unlock
import func os.os_unfair_lock_trylock

final class Storage<Value: ~Copyable> {
  private let _lock: os_unfair_lock_t
  var value: Value

  init(_ initialValue: consuming Value) {
    self._lock = .allocate(capacity: 1)
    self._lock.initialize(to: os_unfair_lock())
    self.value = initialValue
  }

  func lock() {
    os_unfair_lock_lock(_lock)
  }

  func unlock() {
    os_unfair_lock_unlock(_lock)
  }

  func tryLock() -> Bool {
    os_unfair_lock_trylock(_lock)
  }

  deinit {
    self._lock.deinitialize(count: 1)
    self._lock.deallocate()
  }
}

#elseif canImport(Glibc) || canImport(Musl) || canImport(Bionic)

#if canImport(Musl)
import Musl
#elseif canImport(Bionic)
import Android
#else
import Glibc
#endif

final class Storage<Value: ~Copyable> {
  private let _lock: UnsafeMutablePointer<pthread_mutex_t>

  var value: Value

  init(_ initialValue: consuming Value) {
    var attr = pthread_mutexattr_t()
    pthread_mutexattr_init(&attr)
    self._lock = .allocate(capacity: 1)
    let err = pthread_mutex_init(self._lock, &attr)
    precondition(err == 0, "pthread_mutex_init error: \(err)")
    self.value = initialValue
  }

  func lock() {
    let err = pthread_mutex_lock(_lock)
    precondition(err == 0, "pthread_mutex_lock error: \(err)")
  }

  func unlock() {
    let err = pthread_mutex_unlock(_lock)
    precondition(err == 0, "pthread_mutex_unlock error: \(err)")
  }

  func tryLock() -> Bool {
    pthread_mutex_trylock(_lock) == 0
  }

  deinit {
    let err = pthread_mutex_destroy(self._lock)
    precondition(err == 0, "pthread_mutex_destroy error: \(err)")
    self._lock.deallocate()
  }
}

#elseif canImport(WinSDK)

import ucrt
import WinSDK

final class Storage<Value> {
  private let _lock: UnsafeMutablePointer<SRWLOCK>

  var value: Value

  init(_ initialValue: Value) {
    self._lock = .allocate(capacity: 1)
    InitializeSRWLock(self._lock)
    self.value = initialValue
  }

  func lock() {
    AcquireSRWLockExclusive(_lock)
  }

  func unlock() {
    ReleaseSRWLockExclusive(_lock)
  }

  func tryLock() -> Bool {
    TryAcquireSRWLockExclusive(_lock) != 0
  }
}

#endif

#endif
