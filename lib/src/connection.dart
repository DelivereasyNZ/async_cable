import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'channel_identifier.dart';
import 'types.dart';
import 'errors.dart';
import 'channel.dart';

class Connection implements AsyncCableConnection {
  final WebSocket _websocket;
  final Duration _pingTimeout;
  final Completer<Connection> _welcomed = Completer();
  final void Function(AsyncCableError)? _onError;

  final Map<String, Channel> _channels = {};
  StreamSubscription? _websocketSubscription;
  Timer? _pingTimer;

  // Waits for the welcome message, then completes with this connection object.
  // If a disconnect message (or any other message other than welcome) is
  // received, completes with an error and closes the websocket.
  Future<Connection> get connected => _welcomed.future;

  Connection(
    this._websocket, {
    required Duration pingTimeout,
    void Function(AsyncCableError)? onError,
  })  : _pingTimeout = pingTimeout,
        _onError = onError {
    _websocketSubscription = _websocket.listen(_websocketData,
        onError: _websocketError, onDone: _websocketDone);
  }

  void _websocketData(dynamic data) {
    final message = _decodeMessage(data);
    if (message == null) return; // _closeWithError has already been called

    // On connection, an ActionCable server should immediately send either a
    // "welcome" or a "disconnected" message. It can also send a "disconnected"
    // message at any time later. It will send "ping" messages every ~3s by default.
    switch (message["type"]) {
      case "welcome":
        _welcomed.complete(this);
        _resetPingTimer();
        return;

      case "disconnect":
        _closeWithError(_disconnectedError(message["reason"]));
        return;

      case "ping":
        _resetPingTimer();
        return;
    }

    if (!_welcomed.isCompleted) {
      _closeWithError(AsyncCableProtocolError(
          "Received unexpected $data message before welcome"));
      return;
    }

    if (message["identifier"] == null) {
      _closeWithError(AsyncCableProtocolError(
          "Received unexpected message $data with no channel identifier"));
      return;
    }

    // ActionCable identifiers are JSON-encoded strings (embedded in JSON maps,
    // ie. they're doubly JSON-encoded on the wire). But because ActionCable
    // makes them by encoding maps, the order of the JSON keys is not necessarily
    // repeatable, so we need to decode, sort, and re-encode into a string to
    // get a consistent identifier. This is obviously pretty annoying!
    final identifier = ChannelIdentifier.normalize(message["identifier"]);
    final channel = _channels[identifier];

    if (channel == null) {
      _closeWithError(AsyncCableProtocolError(
          "Received unexpected $data message for unknown channel $identifier"));
      return;
    }

    switch (message["type"]) {
      case "confirm_subscription":
        channel.subscriptionConfirmed();
        break;

      case "reject_subscription":
        channel.subscriptionRejected();
        break;

      case null:
        channel.messageReceived(message["message"]);
        break;

      default:
        _closeWithError(AsyncCableProtocolError(
            "Received unexpected ${message["type"]} message for channel $identifier"));
        return;
    }
  }

  dynamic _decodeMessage(dynamic data) {
    if (data is! String) {
      _closeWithError(
          AsyncCableProtocolError("Received invalid non-string message"));
      return null;
    }
    try {
      final result = json.decode(data);
      if (result is Map) return result;
      _closeWithError(AsyncCableProtocolError(
          "Received invalid non-map JSON message $data"));
      return null;
    } on FormatException {
      _closeWithError(
          AsyncCableProtocolError("Received invalid JSON message $data"));
      return null;
    }
  }

  void _resetPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(
      _pingTimeout,
      (_) => _closeWithError(AsyncCablePingTimeoutError()),
    );
  }

  AsyncCableError _disconnectedError(String? reason) {
    if (reason == "unauthorized") {
      return AsyncCableUnauthorized();
    } else if (reason == "invalid_request") {
      return AsyncCableInvalidRequest();
    } else if (reason == "server_restart") {
      return AsyncCableServerRestart();
    } else if (reason == null) {
      return AsyncCableServerClosedConnection();
    } else {
      return AsyncCableProtocolError("Received unexpected $reason disconnect");
    }
  }

  void _closeWithError(AsyncCableError error) {
    _pingTimer?.cancel();
    _pingTimer = null;
    _websocketSubscription?.cancel();
    _websocketSubscription = null;
    _websocket.close();
    for (var channel in _channels.values) {
      channel.closeWithError(error);
    }
    if (!_welcomed.isCompleted) _welcomed.completeError(error);
    _onError?.call(error);
  }

  @override
  void close() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _websocketSubscription?.cancel();
    _websocketSubscription = null;
    _websocket.close();
    for (var channel in _channels.values) {
      channel.close();
    }
  }

  void _websocketError(dynamic error) {
    _closeWithError(AsyncCableNetworkError(error));
  }

  void _websocketDone() {
    // close() and _closeWithError() cancel the subscription before closing the
    // socket, so if the subscription is still present, closing was unexpected.
    if (_websocketSubscription != null) {
      _closeWithError(_welcomed.isCompleted
          ? AsyncCableServerClosedConnection()
          : AsyncCableProtocolError(
              "Connection closed before welcome message"));
    }
  }

  @override
  Channel channel(String name, Map<String, dynamic>? params) {
    if (!name.endsWith("Channel")) {
      throw UnsupportedError(
          "Invalid channel name '$name' (ActionCable requires that channels end with 'Channel')");
    }

    final identifier = ChannelIdentifier.encode(name, params ?? {});

    return _channels[identifier] ??= Channel(
      name: name,
      params: params ?? {},
      identifier: identifier,
      onListen: (Channel channel) {
        _websocket.add(json.encode({
          "command": "subscribe",
          "identifier": identifier,
        }));
      },
      onCancel: (Channel channel) {
        _websocket.add(json.encode({
          "command": "unsubscribe",
          "identifier": identifier,
        }));
      },
      perform: (Channel channel, String action, Map<String, dynamic> data) {
        // ActionCable expects data be double-encoded, like identifier :(
        _websocket.add(json.encode({
          "command": "message",
          "identifier": identifier,
          "data": json.encode({"action": action, ...data}),
        }));
      },
    );
  }
}
