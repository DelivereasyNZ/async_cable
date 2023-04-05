import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async_cable/src/channel_identifier.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:async_cable/async_cable.dart';

class MockWebSocket extends Mock implements WebSocket {}

void main() {
  final String url = "wss://example.com/cable";
  late WebSocket mockWebSocket;
  late Completer<WebSocket> completer;
  late StreamController<dynamic> transport;

  Future<WebSocket> returnCompleter(String url,
      {Iterable<String>? protocols,
      Map<String, dynamic>? headers,
      CompressionOptions compression = CompressionOptions.compressionDefault,
      HttpClient? customClient}) {
    return completer.future;
  }

  void whenListen(Function afterListen) {
    when(() => mockWebSocket.close()).thenAnswer((_) => transport.close());
    when(() => mockWebSocket.listen(any(),
        onError: any(named: 'onError'),
        onDone: any(named: 'onDone'))).thenAnswer((invocation) {
      var onData = invocation.positionalArguments.single;
      var onError = invocation.namedArguments[#onError];
      var onDone = invocation.namedArguments[#onDone];
      final subscription =
          transport.stream.listen(onData, onError: onError, onDone: onDone);
      afterListen();
      return subscription;
    });
  }

  void addWelcome() {
    transport.add(json.encode({"type": "welcome"}));
  }

  setUp(() {
    mockWebSocket = MockWebSocket();
    transport = StreamController<dynamic>.broadcast();
    completer = Completer();
    AsyncCable.connectWebSocket = returnCompleter;
  });

  group('AsyncCable.connect', () {
    group('when the WebSocket connects successfully', () {
      test('returns when the welcome message is received', () async {
        bool connected = false;
        whenListen(() {
          expect(connected, false);
          addWelcome();
        });

        final future = AsyncCable.connect(url);

        completer.complete(mockWebSocket);
        expect(await future, isA<AsyncCableConnection>());
        connected = true;
      });

      test(
          'raises an unauthorized error if an "unauthorized" disconnect message is received',
          () {
        whenListen(() => transport.add(
            json.encode({"type": "disconnect", "reason": "unauthorized"})));
        completer.complete(mockWebSocket);

        expect(AsyncCable.connect(url), throwsA(isA<AsyncCableUnauthorized>()));
      });

      test(
          'raises a protocol error if any other message than welcome is received',
          () {
        whenListen(() => transport.add(json.encode({"type": "other"})));
        completer.complete(mockWebSocket);

        expect(
            AsyncCable.connect(url), throwsA(isA<AsyncCableProtocolError>()));
      });

      test(
          'raises a protocol error if a non-map JSON message is received instead of a welcome message',
          () {
        whenListen(() => transport.add(json.encode(["test"])));
        completer.complete(mockWebSocket);

        expect(
            AsyncCable.connect(url), throwsA(isA<AsyncCableProtocolError>()));
      });

      test(
          'raises a protocol error if an invalid JSON string is received instead of a welcome message',
          () {
        whenListen(() => transport.add("foo: bar"));
        completer.complete(mockWebSocket);

        expect(
            AsyncCable.connect(url), throwsA(isA<AsyncCableProtocolError>()));
      });

      test(
          'raises a protocol error if a binary message is received instead of a welcome message',
          () {
        whenListen(() => transport.add(List<int>.filled(100, 0)));
        completer.complete(mockWebSocket);

        expect(
            AsyncCable.connect(url), throwsA(isA<AsyncCableProtocolError>()));
      });

      test(
          'raises a protocol error if the socket is closed instead of a welcome message received',
          () {
        whenListen(
            () => Future.delayed(Duration.zero, () => transport.close()));
        completer.complete(mockWebSocket);

        expect(
            AsyncCable.connect(url), throwsA(isA<AsyncCableProtocolError>()));
      });

      test(
          'raises a network error if no welcome message is received before timeout',
          () {
        whenListen(() {});
        completer.complete(mockWebSocket);

        expect(
            AsyncCable.connect(url, connectTimeout: Duration(milliseconds: 50)),
            throwsA(isA<AsyncCableNetworkError>()));
      });
    });

    group('when the WebSocket connect fails', () {
      test('raises a network error', () {
        completer.completeError("dummy error of any type");

        expect(AsyncCable.connect(url), throwsA(isA<AsyncCableNetworkError>()));
      });
    });

    group('when the WebSocket connect does nothing before timeout', () {
      test('raises a network error', () {
        // do nothing on completer

        expect(
            AsyncCable.connect(url, connectTimeout: Duration(milliseconds: 50)),
            throwsA(isA<AsyncCableNetworkError>()));
      });
    });
  });

  group('AsyncCableConnnection', () {
    setUp(() async {
      completer.complete(mockWebSocket);
      whenListen(() => addWelcome());
    });

    group('heartbeats', () {
      late AsyncCableConnection connection;
      dynamic deliveredError;

      setUp(() async {
        connection = await AsyncCable.connect(url,
            pingTimeout: Duration(milliseconds: 50),
            onError: (error) => deliveredError = error);
      });

      test(
          'delivers a ping timeout error if no ping message is received for the given time',
          () async {
        await Future.delayed(Duration(milliseconds: 20));
        expect(deliveredError, isNull);

        transport.add('{"type":"ping","message":1234}');
        await Future.delayed(Duration(milliseconds: 40));
        expect(deliveredError, isNull);

        await Future.delayed(Duration(milliseconds: 20));
        expect(deliveredError, isA<AsyncCablePingTimeoutError>());
      });
    });

    group('error reporting', () {
      late AsyncCableConnection connection;
      dynamic deliveredError;

      setUp(() async {
        deliveredError = null;
        connection = await AsyncCable.connect(url,
            onError: (error) => deliveredError = error);
      });

      test(
          'delivers a server restart error if a "server_restart" disconnect message is received',
          () async {
        transport.add(
            json.encode({"type": "disconnect", "reason": "server_restart"}));
        await Future.delayed(Duration.zero);

        expect(deliveredError, isA<AsyncCableServerRestart>());
      });

      test(
          'delivers a closed connection error if a disconnect message with no reason is received',
          () async {
        transport.add(json.encode({"type": "disconnect"}));
        await Future.delayed(Duration.zero);

        expect(deliveredError, isA<AsyncCableServerClosedConnection>());
      });

      test(
          'delivers a closed connection error if the stream is closed without a disconnect message',
          () async {
        transport.close();
        await Future.delayed(Duration.zero);

        expect(deliveredError, isA<AsyncCableServerClosedConnection>());
      });

      test('delivers a network error if the stream delivers any error',
          () async {
        transport.addError("dummy websocket error");
        await Future.delayed(Duration.zero);

        expect(deliveredError, isA<AsyncCableNetworkError>());
      });

      test('delivers a protocol error if a non-map JSON message is received',
          () async {
        transport.add(json.encode(["test"]));
        await Future.delayed(Duration.zero);

        expect(deliveredError, isA<AsyncCableProtocolError>());
      });

      test('delivers a protocol error if an invalid JSON string is received',
          () async {
        transport.add("foo: bar");
        await Future.delayed(Duration.zero);

        expect(deliveredError, isA<AsyncCableProtocolError>());
      });

      test('delivers a protocol error if a binary message is received',
          () async {
        transport.add(List<int>.filled(100, 0));
        await Future.delayed(Duration.zero);

        expect(deliveredError, isA<AsyncCableProtocolError>());
      });

      test('delivers no error if the connection is explicitly closed',
          () async {
        connection.close();
        await Future.delayed(Duration.zero);

        expect(deliveredError, isNull);
      });
    });
  });

  group('ChannelIdentifier', () {
    group('encode', () {
      test('correctly encodes channel names with no params', () {
        expect(ChannelIdentifier.encode("SomeChannel", {}),
            '{"channel":"SomeChannel"}');
      });

      test(
          'correctly encodes channel names with params in a sorted format that ignores input order',
          () {
        expect(
            ChannelIdentifier.encode("SomeChannel", {"foo": "bar", "baz": 1}),
            '{"baz":1,"channel":"SomeChannel","foo":"bar"}');
        expect(
            ChannelIdentifier.encode("SomeChannel", {"baz": 1, "foo": "bar"}),
            '{"baz":1,"channel":"SomeChannel","foo":"bar"}');
      });
    });
  });

  group('AsyncCableConnection.channel', () {
    late AsyncCableConnection connection;
    late AsyncCableChannel channel;

    setUp(() async {
      completer.complete(mockWebSocket);
      whenListen(() => addWelcome());

      connection = await AsyncCable.connect(url);
      channel = connection.channel("SomeTestChannel", {});

      when(() => mockWebSocket.add(any())).thenReturn(null);
    });

    group('subscription requests', () {
      test(
          'sends a subscribe command, with the channel identifier double-encoded',
          () async {
        expect(channel.status, AsyncCableChannelStatus.unsubscribed);

        channel.messages.listen((_) {});

        expect(channel.status, AsyncCableChannelStatus.subscribing);
        verify(() => mockWebSocket.add(
            '{"command":"subscribe","identifier":"{\\"channel\\":\\"SomeTestChannel\\"}"}'));
      });

      test('becomes subscribed if the subscription is confirmed', () async {
        dynamic receivedError;
        channel.messages
            .listen((_) {}, onError: (error) => receivedError = error);
        expect(channel.status, AsyncCableChannelStatus.subscribing);

        transport.add(
            '{"type":"confirm_subscription","identifier":"{\\"channel\\":\\"SomeTestChannel\\"}"}');
        await Future.delayed(Duration.zero);

        expect(channel.status, AsyncCableChannelStatus.subscribed);
        expect(receivedError, isNull);
      });

      test(
          'delivers an error on the messages stream if the subscription is rejected',
          () async {
        dynamic receivedError;
        channel.messages
            .listen((_) {}, onError: (error) => receivedError = error);
        expect(channel.status, AsyncCableChannelStatus.subscribing);

        transport.add(
            '{"type":"reject_subscription","identifier":"{\\"channel\\":\\"SomeTestChannel\\"}"}');
        await Future.delayed(Duration.zero);

        expect(channel.status, AsyncCableChannelStatus.rejected);
        expect(receivedError, isA<AsyncCableSubscriptionRejected>());
      });

      test('is immediately done if the connection is already closed', () async {
        connection.close();
        expect(channel.status, AsyncCableChannelStatus.disconnected);

        dynamic receivedError;
        bool done = false;
        channel.messages.listen((_) {},
            onError: (error) => receivedError = error,
            onDone: () => done = true);
        await Future.delayed(Duration.zero);
        expect(channel.status, AsyncCableChannelStatus.disconnected);
        expect(done, true);
        expect(receivedError, isNull);
      });
    });

    group('subscribed channels', () {
      late StreamSubscription<dynamic> subscription;
      List<dynamic> deliveredMessages = [];
      dynamic deliveredError;

      setUp(() {
        deliveredMessages = [];
        deliveredError = null;
        subscription = channel.messages.listen(
            (message) => deliveredMessages.add(message),
            onError: (error) => deliveredError = error);
        transport.add(
            '{"type":"confirm_subscription","identifier":"{\\"channel\\":\\"SomeTestChannel\\"}"}');
      });

      test('delivers messages received on the channel', () async {
        transport.add(
            '{"identifier":"{\\"channel\\":\\"SomeTestChannel\\"}","message":{"somedata":"Sent by server"}}');
        transport.add(
            '{"identifier":"{\\"channel\\":\\"SomeTestChannel\\"}","message":100}');
        await Future.delayed(Duration.zero);

        expect(deliveredMessages[0], {"somedata": "Sent by server"});
        expect(deliveredMessages[1], 100);
        expect(deliveredError, isNull);
        expect(channel.status, AsyncCableChannelStatus.subscribed);
      });

      test('delivers connection errors as channel message stream errors',
          () async {
        transport.add(
            json.encode({"type": "disconnect", "reason": "server_restart"}));
        await Future.delayed(Duration.zero);

        expect(deliveredError, isA<AsyncCableServerRestart>());
        expect(channel.status, AsyncCableChannelStatus.disconnected);
      });

      test(
          'closes the messages stream without error if the connection is explicitly closed',
          () async {
        connection.close();

        expect(channel.status, AsyncCableChannelStatus.disconnected);
        await Future.delayed(Duration.zero);
        expect(deliveredError, isNull);
      });

      test(
          'returns to an unsubscribed state if the messages subscription is cancelled',
          () async {
        subscription.cancel();

        expect(channel.status, AsyncCableChannelStatus.unsubscribed);
        await Future.delayed(Duration.zero);
        expect(deliveredError, isNull);
      });

      test('allows re-subscription after unsubscription', () async {
        subscription.cancel();
        expect(channel.status, AsyncCableChannelStatus.unsubscribed);

        subscription = channel.messages.listen(
            (message) => deliveredMessages.add(message),
            onError: (error) => deliveredError = error);
        expect(channel.status, AsyncCableChannelStatus.subscribing);

        transport.add(
            '{"type":"confirm_subscription","identifier":"{\\"channel\\":\\"SomeTestChannel\\"}"}');
        await Future.delayed(Duration.zero);

        expect(channel.status, AsyncCableChannelStatus.subscribed);
        expect(deliveredError, isNull);
        verify(() => mockWebSocket.add(
                '{"command":"subscribe","identifier":"{\\"channel\\":\\"SomeTestChannel\\"}"}'))
            .called(2);
      });
    });
  });
}
