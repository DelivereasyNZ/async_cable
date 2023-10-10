class AsyncCableError extends Error {
  @override
  String toString() => runtimeType.toString();
}

class AsyncCableProtocolError extends AsyncCableError {
  String error;

  AsyncCableProtocolError(this.error);

  @override
  String toString() => "AsyncCableProtocolError: $error";
}

class AsyncCableUnauthorized extends AsyncCableError {}

class AsyncCableInvalidRequest extends AsyncCableError {}

class AsyncCableServerRestart extends AsyncCableError {}

class AsyncCableServerClosedConnection extends AsyncCableError {}

class AsyncCablePingTimeoutError extends AsyncCableError {}

class AsyncCableNetworkError extends AsyncCableError {
  Object error;

  AsyncCableNetworkError(this.error);

  @override
  String toString() => "AsyncCableNetworkError: $error";
}

class AsyncCableSubscriptionRejected extends AsyncCableError {
  AsyncCableSubscriptionRejected();
}
