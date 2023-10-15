## 1.2.2

- Early-return from `close()` if already closed.

## 1.2.1

- Complete the `connected` future with a `AsyncCableClientClosedConnection` error if `close()` is called.

## 1.2.0

- Emit `AsyncCableClientClosedConnection` instead of `StateError` from subscription futures if `close()` is called.
- Fix `Future` error when calling `close()` twice.

## 1.1.4

- Error class `toString()` improvements.

## 1.1.3

- Defer cancelling the stream subscription to workaround race in `SecureSocket`.

## 1.1.2

- Synchronously convert the stream controller into channels to avoid the possibility of missing a channel message received on the websocket straight after the `confirm_subscription`.

## 1.1.1

- Don't try to send unsubscribe messages if the channel is already closed.

## 1.1.0

- Add `isConnectionClosed` on `AsyncCableChannel` (matching `isClosed` on `AsyncCableConnection`).

## 1.0.0

- Initial version.
