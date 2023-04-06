import 'dart:async';

import 'errors.dart';

/// One channel in an ActionCable connection.
///
/// Channels are multiplexed onto a single Websocket connection and live only as
/// long as their connection.
///
/// Channel objects are created by calling [AsyncCableConnection.subscribe],
/// which waits for the server to confirm or reject the subscription, and only
/// returns the channel if confirmed.
///
/// Channel objects are created each time [AsyncCableConnection.subscribe] is
/// called, but only one underlying subscription to the channel is made.
/// When the last subscriber cancels the subscription, an `unsubscribe` message
/// will be sent to the server, the stream will be immediately closed (there's
/// no protocol-level acknowledgement for unsubscribe requests in ActionCable).
///
/// If a connection-level error occurs, it will be delivered as an error on
/// every channel's stream. Since the connection is closed on errors, a new
/// connection then needs to be created and a new channel object created.
///
/// You must subscribe to a channel before performing actions, as ActionCable
/// servers ignore messages on non-subscribed channels (since they have not been
/// authorized).
abstract class AsyncCableChannel {
  /// The channel name.
  String get name;

  /// Any channel parameters.
  Map<String, dynamic> get params;

  /// The channel message stream subscription.
  ///
  /// New StreamSubscription and Channel objects are created every time you call
  /// [AsyncCableConnection.subscribe], but there'll be only one subscription
  /// from the ActionCable server's end.
  StreamSubscription<dynamic> get subscription;

  /// Closes this channel message stream subscription, and if this was the last
  /// stream subscription, sends an unsubscribe request to the server.
  ///
  /// This is identical to calling [subscription.cancel()].
  void cancel();

  /// Sends a command message on this connection.
  ///
  /// Sending commands in ActionCable is fire-and-forget; there's no protocol-level
  /// acknowledgement that the command was received or processed successfully. Any
  /// response from the server will be delivered on the stream as normal.
  void perform(String action, [Map<String, dynamic> data]);
}

/// A connection to the ActionCable endpoint.
///
/// Create connections using [AsyncCable.connect].
///
/// A connection's lifetime matches the underlying Websocket. When a connection
/// fails, a new connection needs to be made.
///
/// Connections implement the protocol described at https://docs.anycable.io/misc/action_cable_protocol
/// over `dart:io` Websockets.
abstract class AsyncCableConnection {
  /// Subscribes to the specified channel and listens for messages.
  ///
  /// If this is the first subscription for the channel, this causes a `subscribe`
  /// message to be sent to the server. If the server confirms the subscription,
  /// the future completes with the new channel object, and the stream starts
  /// delivering messages. If the server rejects the subscription, the future
  /// completes with an [AsyncCableSubscriptionRejected] error.
  ///
  /// Channel objects are created each time [AsyncCableConnection.subscribe] is
  /// called, but only one underlying subscription to the channel is made.
  /// When the last subscriber cancels the subscription, an `unsubscribe` message
  /// will be sent to the server, after which it can be subscribed again.
  ///
  /// If an error occurs while waiting for the server to respond to the
  /// subscription request, the future completes with an error, which will be one
  /// of the [AsyncCableError] subclasses. If [close()] is called while waiting
  /// for the server to respond to the subscription request, the future completes
  /// with a [StateError] error. If the connection is already closed when this
  /// method is called, throws a [StateError] immediately.
  ///
  /// Channel subscriptions always have cancelOnError semantics as nothing can
  /// happen once a subscription is rejected or a connection encounters an error.
  Future<AsyncCableChannel> subscribe(
      String channelName,
      Map<String, dynamic>? channelParams,
      void Function(dynamic message)? onData,
      {void Function(dynamic error)? onError,
      void Function()? onDone});

  /// Closes the connection and all channels within it.
  ///
  /// Called automatically if the Websocket connection delivers a `disconnect`
  /// message or a network error occurs.
  void close();

  /// Returns true if the connection has been closed, whether explicitly using
  /// close(), by the server gracefully, or by a network error.
  bool get isClosed;
}
