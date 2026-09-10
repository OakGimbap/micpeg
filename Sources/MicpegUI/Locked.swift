// One value, written on one thread and read on another.
//
// Three of these appeared in one stage: the level meter's latest sample (audio render thread →
// main actor), the meter diagnostic's sample buffer, and the completion result of a
// semaphore-blocked call. Each was a hand-rolled `final class … @unchecked Sendable` with an
// `NSLock`. `@unchecked Sendable` is the point where the compiler stops checking, so having
// one of them rather than three is worth the file.

import Foundation

public final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    public init(_ value: Value) { self.value = value }

    public func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    public func withValue<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
