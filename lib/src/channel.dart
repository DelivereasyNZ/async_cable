import 'dart:async';

import 'types.dart';
import 'errors.dart';

class Channel implements AsyncCableChannel {
  @override
  final String name;

  @override
  final Map<String, dynamic> params;

  @override
  Stream<AsyncCableMessage> get messages => _messagesController.stream;

  @override
  AsyncCableChannelStatus status = AsyncCableChannelStatus.unsubscribed;

  @override
  Stream<AsyncCableChannelStatus> get statuses => _statusesController.stream;

  final String identifier;
  final Function(Channel, Map<String, dynamic>) _sendCommand;
  final StreamController<AsyncCableChannelStatus> _statusesController =
      StreamController.broadcast();
  late StreamController<AsyncCableMessage> _messagesController;

  Channel(
      {required this.name,
      required this.params,
      required this.identifier,
      required void Function(Channel) onListen,
      required void Function(Channel) onCancel,
      required void Function(Channel, Map<String, dynamic>) sendCommand})
      : _sendCommand = sendCommand {
    _messagesController = StreamController.broadcast(onListen: () {
      _setStatus(AsyncCableChannelStatus.subscribing);
      onListen(this);
    }, onCancel: () {
      if (status != AsyncCableChannelStatus.disconnected) {
        _setStatus(AsyncCableChannelStatus.unsubscribed);
        onCancel(this);
      }
    });
  }

  @override
  void sendCommand(Map<String, dynamic> data) {
    _sendCommand(this, data);
  }

  void _setStatus(AsyncCableChannelStatus s) {
    status = s;
    _statusesController.add(status);
  }

  void subscriptionConfirmed() {
    if (status == AsyncCableChannelStatus.subscribing) {
      _setStatus(AsyncCableChannelStatus.subscribed);
    }
  }

  void subscriptionRejected() {
    if (status == AsyncCableChannelStatus.subscribing) {
      _setStatus(AsyncCableChannelStatus.rejected);
      _messagesController.addError(AsyncCableSubscriptionRejected(this));
    }
  }

  void messageReceived(dynamic message) {
    // Ignore any trailing messages received after we unsubscribe. Of course,
    // there will be no listeners on the messages stream at the point we send an
    // unsubscribe, since that's what triggers onCancel/unsubscribe, but if a
    // new subscription is created immediately after it's possible for an old
    // message that was already in the pipe to be received while we're still in
    // the subscribing state, and we want to ignore those until we receive the
    // confirm_subscription/reject_subscription.
    if (status == AsyncCableChannelStatus.subscribed) {
      _messagesController
          .add(AsyncCableMessage(channel: this, message: message));
    }
  }

  void close() {
    if (status != AsyncCableChannelStatus.disconnected) {
      _setStatus(AsyncCableChannelStatus.disconnected);
      _messagesController.close();
    }
  }

  void closeWithError(AsyncCableError error) {
    if (status != AsyncCableChannelStatus.disconnected) {
      _setStatus(AsyncCableChannelStatus.disconnected);
      _messagesController.addError(error);
      _messagesController.close();
    }
  }
}
