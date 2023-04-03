import 'dart:async';

/// A single message received from an ActionCable connection.
class AsyncCableMessage {
  /// The channel.
  final AsyncCableChannel channel;

  /// The received message.
  final dynamic message;

  @override
  String toString() => message.toString();

  AsyncCableMessage({required this.channel, required this.message});
}

/// Describes the state of an [AsyncCableChannel].
///
/// See [AsyncCableChannel.status] for the state flow.
enum AsyncCableChannelStatus {
  unsubscribed,
  subscribing,
  subscribed,
  rejected,
  disconnected
}

/// One channel in an ActionCable connection.
///
/// Channels are multiplexed onto a single Websocket connection and live only as
/// long as their connection.
///
/// Channel objects are created by calling [AsyncCableConnection.channel], which
/// returns them in the [AsyncCableChannelStatus.unsubscribed] state.
///
/// They can be used immediately for sending commands, without subscribing.
///
/// To receive messages, callers need to listen to the [messages] stream. This
/// causes a `subscribe` message to be sent to the server, and [status] will
/// change to [AsyncCableChannelStatus.subscribing]. When the server responds,
/// [status] will change to [AsyncCableChannelStatus.subscribed] or
/// [AsyncCableChannelStatus.rejected], and if rejected, an
/// [AsyncCableSubscriptionRejected] error will be delivered on the [messages]
/// stream.
///
/// When the last subscriber to the [messages] stream cancels the subscription,
/// an `unsubscribe` method will be sent to the server, and [status] will
/// change to [AsyncCableChannelStatus.unsubscribed] again immediately (there's
/// no response to `unsubscribe` messages in the ActionCable protocol). New
/// subscriptions may then be created and the lifecycle will repeat.
///
/// If a connection-level error occurs, it will be delivered as an error on
/// every channel's [messages] stream, and [status] will change to
/// [AsyncCableChannelStatus.disconnected]. Since the connection is closed on
/// errors, a new connection then needs to be created and a new channel object
/// created.
///
/// All status changes are delivered on the [statuses] stream. Because
/// subscription rejections and disconnects are delivered as errors on the
/// [messages] stream, in practice it is only necessary to listen on the
/// [statuses] stream if you want positive confirmation of subscription events
/// too.
abstract class AsyncCableChannel {
  /// The channel name.
  String get name;

  /// Any channel parameters.
  Map<String, dynamic> get params;

  /// Stream of all messages received for this channel.
  ///
  /// The stream will deliver errors if the channel subscription is "rejected"
  /// by the server, if the connection is disconnected, or fails for any reason.
  /// Errors will be one of the subclasses of [AsyncCableError].
  Stream<AsyncCableMessage> get messages;

  /// Current status of this channel.
  ///
  /// See [AsyncCableChannel] for a detailed explanation of the lifecycle.
  AsyncCableChannelStatus get status;

  /// Stream of the channel status values, as described by [status].
  ///
  /// See [AsyncCableChannel] for a detailed explanation of the lifecycle.
  ///
  /// Because subscription rejections and connection disconnects are delivered
  /// as errors on the [messages] stream, most often it is only necessary to
  /// listen on the [statuses] stream if you want positive confirmation of
  /// subscription events too, or want a simple way to update the UI to show
  /// the status of the channel.
  ///
  /// This stream delivers notice of error states such as
  /// [AsyncCableChannelStatus.rejected] and [AsyncCableChannelStatus.disconnected]
  /// as values, not errors. Use the [messages] stream to get error objects.
  Stream<AsyncCableChannelStatus> get statuses;

  /// Sends a command message on this connection.
  ///
  /// The convention is that the data contain an "action" field, which is a string.
  ///
  /// Sending commands in ActionCable is fire-and-forget; there's no protocol-level
  /// acknowledgement that the command was received or processed successfully. Any
  /// response from the server will be delivered on the [messages] stream as normal.
  void sendCommand(Map<String, dynamic> data);
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
  /// Returns the specified channel, without starting the subscription.
  AsyncCableChannel channel(String name, Map<String, dynamic>? params);

  /// Closes the connection and all channels within it.
  ///
  /// Called automatically if the Websocket connection delivers a `disconnect`
  /// message or a network error occurs.
  void close();
}
