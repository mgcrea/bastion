import Foundation

/// A JSON value carried across a thread or actor boundary.
///
/// JSON-RPC ids, handshakes and tool catalogs are `Any` and `[String: Any]`
/// throughout the gateway, because that is what `JSONSerialization` hands back.
/// `Any` can never prove it is Sendable, so under Swift 6 none of them may be
/// stored behind a lock or captured by a `@Sendable` closure, which is exactly
/// where the supervisor keeps them. A typed JSON enum would say the same thing
/// without `@unchecked`, at the price of rewriting every dictionary lookup in
/// the gateway.
///
/// `@unchecked` is sound for what goes in here, and only for that: values
/// parsed by `JSONSerialization` (never with `.mutableContainers`), and literals
/// of strings, numbers, booleans, arrays and dictionaries. Those are Swift value
/// types and immutable Foundation objects (`NSString`, `NSNumber`, `NSNull`,
/// `NSArray`, `NSDictionary`), so nothing reachable from one can change after
/// it is built, which is the guarantee `Sendable` asks for. Never wrap anything
/// that holds a reference to a mutable object.
nonisolated struct SendableJSON<Value>: @unchecked Sendable {
  let value: Value

  init(_ value: Value) { self.value = value }
}
