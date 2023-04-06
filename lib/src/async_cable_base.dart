import 'dart:io';

import 'types.dart';
import 'errors.dart';
import 'connection.dart';

/// Creates connections to ActionCable endpoints.
class AsyncCable {
  /// @nodoc Internal stub overridden for tests.
  static var connectWebSocket = WebSocket.connect;

  static const defaultConnectTimeout = Duration(seconds: 30);
  static const defaultPingTimeout = Duration(seconds: 6);

  /// Connects to the given ActionCable endpoint and waits for the `welcome` handshake.
  ///
  /// The future will complete with an [AsyncCableConnection] object if the WebSocket
  /// connection and the `welcome` handshake are both successful, or will fail with
  /// an [AsyncCableError] error such as [AsyncCableUnauthorized] if not.
  ///
  /// Once successfully connected, any connection-level errors will result in the
  /// connection being closed and the optional [onError] callback will be called
  /// with an [AsyncCableError]. The error will also be delivered on each channel
  /// stream, so using [onError] is optional and in practice only needed when you
  /// want to centralize handling of connection-level errors.
  ///
  /// Once successfully connected, expects to receive a ping from the server periodically,
  /// and if not received, delivers a [AsyncCablePingTimeoutError] to the channel streams
  /// and to the optional [onError] callback. The default ping timeout is 6 seconds, which is
  /// twice the default Rails ActionCable ping interval. After a timeout, the connection
  /// is closed.
  ///
  /// After any errors, you must reconnect using this method to restart communication.
  static Future<AsyncCableConnection> connect(
    String url, {
    Map<String, dynamic>? headers,
    HttpClient? customClient,
    Duration connectTimeout = defaultConnectTimeout,
    Duration pingTimeout = defaultPingTimeout,
    void Function(AsyncCableError)? onError,
  }) {
    return connectWebSocket(url,
            headers: headers ?? {}, customClient: customClient)
        .onError((error, _) =>
            throw AsyncCableNetworkError(error ?? "Unknown Websocket error"))
        .then((websocket) =>
            Connection(websocket, pingTimeout: pingTimeout, onError: onError)
                .connected)
        .timeout(
          connectTimeout,
          onTimeout: () => throw AsyncCableNetworkError("Connection timeout"),
        );
  }
}
