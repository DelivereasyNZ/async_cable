import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'channel_identifier.dart';
import 'types.dart';
import 'errors.dart';

class Channel implements AsyncCableChannel {
  @override
  final String name;

  @override
  final Map<String, dynamic> params;

  @override
  final StreamSubscription subscription;

  @override
  bool get isConnectionClosed => _connection.isClosed;

  final AsyncCableConnection _connection;
  final Function(String, Map<String, dynamic>) _perform;

  Channel(this._connection,
      {required this.name,
      required this.params,
      required this.subscription,
      required void Function(String, Map<String, dynamic>) perform})
      : _perform = perform;

  @override
  void cancel() {
    subscription.cancel();
  }

  @override
  void perform(String action, [Map<String, dynamic>? data]) {
    _perform(action, data ?? {});
  }
}

class Connection implements AsyncCableConnection {
  final WebSocket _websocket;
  final Duration _pingTimeout;
  final Completer<Connection> _welcomed = Completer();
  final void Function(AsyncCableError)? _onError;

  final Map<String, Completer<StreamController>> _pending = {};
  final Map<String, StreamController> _controllers = {};
  StreamSubscription? _websocketSubscription;
  Timer? _pingTimer;
  bool _isClosed = false;
  dynamic _error;

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

  @override
  Future<AsyncCableChannel> subscribe(
      String channelName,
      Map<String, dynamic>? channelParams,
      void Function(dynamic message)? onData,
      {void Function(dynamic error)? onError,
      void Function()? onDone}) {
    if (!channelName.endsWith("Channel")) {
      throw UnsupportedError(
          "Invalid channel name '$channelName' (ActionCable requires that channel names end with 'Channel')");
    }
    if (isClosed) {
      // We wrap these errors in a future rather than raising as a convenience
      // to callers, to avoid them needing to handle network errors both synchronously
      // and asynchronously.
      return Future.error(_error ??
          StateError("Can't subscribe to a channel on a closed connection"));
    }

    final identifier =
        ChannelIdentifier.encode(channelName, channelParams ?? {});

    return _subscribe(identifier).then((controller) {
      return Channel(
        this,
        name: channelName,
        params: channelParams ?? {},
        subscription: controller.stream.listen(onData,
            onError: onError, onDone: onDone, cancelOnError: true),
        perform: (String action, Map<String, dynamic> params) =>
            _perform(identifier, action, params),
      );
    });
  }

  @override
  bool get isClosed => _isClosed;

  void _websocketData(dynamic data) {
    if (_isClosed) return;

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

    switch (message["type"]) {
      case "confirm_subscription":
        final completer = _pending.remove(identifier);
        if (completer != null) {
          final controller = StreamController.broadcast(
              onCancel: () => _unsubscribe(identifier));
          _controllers[identifier] = controller;
          completer.complete(controller);
        } else {
          _closeWithError(AsyncCableProtocolError(
              "Received unexpected $data message for unknown channel $identifier"));
        }
        break;

      case "reject_subscription":
        final completer = _pending.remove(identifier);
        if (completer != null) {
          completer.completeError(AsyncCableSubscriptionRejected());
        } else {
          _closeWithError(AsyncCableProtocolError(
              "Received unexpected $data message for unknown channel $identifier"));
        }
        break;

      case null:
        final controller = _controllers[identifier];

        if (controller != null) {
          controller.add(message["message"]);
        } else {
          _closeWithError(AsyncCableProtocolError(
              "Received unexpected $data message for unknown channel $identifier"));
        }
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
    _isClosed = true;
    _error = error;
    _pingTimer?.cancel();
    _pingTimer = null;
    _websocket.close();
    for (var controller in _controllers.values) {
      controller.addError(error);
      controller.close();
    }
    for (var completer in _pending.values) {
      completer.completeError(error);
    }
    if (!_welcomed.isCompleted) _welcomed.completeError(error);
    _onError?.call(error);
  }

  @override
  void close() {
    _isClosed = true;
    _pingTimer?.cancel();
    _pingTimer = null;
    _websocket.close();
    for (var controller in _controllers.values) {
      controller.close();
    }
    for (var completer in _pending.values) {
      completer
          .completeError(StateError("Connection was closed while subscribing"));
    }
  }

  void _websocketError(dynamic error) {
    _closeWithError(AsyncCableNetworkError(error));
  }

  void _websocketDone() {
    // close() and _closeWithError() set _done before closing the socket, so if
    // that's false, closing was unexpected.
    if (!_isClosed) {
      _closeWithError(_welcomed.isCompleted
          ? AsyncCableServerClosedConnection()
          : AsyncCableProtocolError(
              "Connection closed before welcome message"));
    }

    // Due to a race condition in the dart:io SecureSocket class, we need to
    // avoid cancelling the subscription until the done callback fires.
    _websocketSubscription?.cancel();
    _websocketSubscription = null;
  }

  Future<StreamController> _subscribe(String identifier) {
    final completed = _controllers[identifier];
    if (completed != null) return Future.value(completed);

    final inProgress = _pending[identifier];
    if (inProgress != null) return inProgress.future;

    final completer = Completer<StreamController>.sync();
    _pending[identifier] = completer;
    _websocket.add(json.encode({
      "command": "subscribe",
      "identifier": identifier,
    }));
    return completer.future;
  }

  void _unsubscribe(String identifier) {
    _controllers.remove(identifier);

    if (!isClosed) {
      _websocket.add(json.encode({
        "command": "unsubscribe",
        "identifier": identifier,
      }));
    }
  }

  void _perform(String identifier, String action, Map<String, dynamic> data) {
    _websocket.add(json.encode({
      "command": "message",
      "identifier": identifier,
      // ActionCable expects data be double-encoded, like identifier :(
      "data": json.encode({"action": action, ...data}),
    }));
  }
}
