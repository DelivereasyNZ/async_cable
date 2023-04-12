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
        expect(connection.isClosed, true);
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
        expect(connection.isClosed, true);
      });

      test(
          'delivers a closed connection error if a disconnect message with no reason is received',
          () async {
        transport.add(json.encode({"type": "disconnect"}));
        await Future.delayed(Duration.zero);

        expect(deliveredError, isA<AsyncCableServerClosedConnection>());
        expect(connection.isClosed, true);
      });

      test(
          'delivers a closed connection error if the stream is closed without a disconnect message',
          () async {
        transport.close();
        await Future.delayed(Duration.zero);

        expect(deliveredError, isA<AsyncCableServerClosedConnection>());
        expect(connection.isClosed, true);
      });

      test('delivers a network error if the stream delivers any error',
          () async {
        transport.addError("dummy websocket error");
        await Future.delayed(Duration.zero);

        expect(deliveredError, isA<AsyncCableNetworkError>());
        expect(connection.isClosed, true);
      });

      test('delivers a protocol error if a non-map JSON message is received',
          () async {
        transport.add(json.encode(["test"]));
        await Future.delayed(Duration.zero);

        expect(deliveredError, isA<AsyncCableProtocolError>());
        expect(connection.isClosed, true);
      });

      test('delivers a protocol error if an invalid JSON string is received',
          () async {
        transport.add("foo: bar");
        await Future.delayed(Duration.zero);

        expect(deliveredError, isA<AsyncCableProtocolError>());
        expect(connection.isClosed, true);
      });

      test('delivers a protocol error if a binary message is received',
          () async {
        transport.add(List<int>.filled(100, 0));
        await Future.delayed(Duration.zero);

        expect(deliveredError, isA<AsyncCableProtocolError>());
        expect(connection.isClosed, true);
      });

      test('delivers no error if the connection is explicitly closed',
          () async {
        connection.close();
        await Future.delayed(Duration.zero);

        expect(deliveredError, isNull);
        expect(connection.isClosed, true);
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

  group('AsyncCableConnection.subscribe', () {
    late AsyncCableConnection connection;

    setUp(() async {
      completer.complete(mockWebSocket);
      whenListen(() => addWelcome());

      connection = await AsyncCable.connect(url);

      when(() => mockWebSocket.add(any())).thenReturn(null);
    });

    group('subscription requests', () {
      test(
          'sends a subscribe command, with the channel identifier double-encoded',
          () async {
        connection.subscribe("SomeTestChannel", {}, null);

        verify(() => mockWebSocket.add(
            '{"command":"subscribe","identifier":"{\\"channel\\":\\"SomeTestChannel\\"}"}'));
      });

      test('becomes subscribed if the subscription is confirmed', () async {
        bool completed = false;
        dynamic receivedError;
        final future = connection
            .subscribe("SomeTestChannel", {}, null,
                onError: (error) => receivedError = error)
            .whenComplete(() => completed = true);

        await Future.delayed(Duration.zero);
        expect(completed, false);

        transport.add(
            '{"type":"confirm_subscription","identifier":"{\\"channel\\":\\"SomeTestChannel\\"}"}');
        await Future.delayed(Duration.zero);

        expect(completed, true);
        expect(await future, isA<AsyncCableChannel>());
        expect(receivedError, isNull);
      });

      test('throws an error if the subscription is rejected', () async {
        final future = connection.subscribe("SomeTestChannel", {}, null);

        transport.add(
            '{"type":"reject_subscription","identifier":"{\\"channel\\":\\"SomeTestChannel\\"}"}');
        expect(future, throwsA(isA<AsyncCableSubscriptionRejected>()));
      });

      test('only sends a subscribe command if the channel is subscribed twice',
          () async {
        final future1 = connection.subscribe("SomeTestChannel", {}, null);
        final future2 = connection.subscribe("SomeTestChannel", {}, null);

        transport.add(
            '{"type":"confirm_subscription","identifier":"{\\"channel\\":\\"SomeTestChannel\\"}"}');
        await Future.delayed(Duration.zero);

        expect(await future1, isA<AsyncCableChannel>());
        expect(await future2, isA<AsyncCableChannel>());

        verify(() => mockWebSocket.add(
                '{"command":"subscribe","identifier":"{\\"channel\\":\\"SomeTestChannel\\"}"}'))
            .called(1);
      });

      test(
          'only sends one subscribe command if the channel is subscribed twice, and confirmed in between',
          () async {
        final future1 = connection.subscribe("SomeTestChannel", {}, null);
        transport.add(
            '{"type":"confirm_subscription","identifier":"{\\"channel\\":\\"SomeTestChannel\\"}"}');
        await Future.delayed(Duration.zero);
        expect(await future1, isA<AsyncCableChannel>());

        final future2 = connection.subscribe("SomeTestChannel", {}, null);
        await Future.delayed(Duration.zero);
        expect(await future2, isA<AsyncCableChannel>());

        verify(() => mockWebSocket.add(
                '{"command":"subscribe","identifier":"{\\"channel\\":\\"SomeTestChannel\\"}"}'))
            .called(1);
      });

      test('allows re-subscription after unsubscription', () async {
        final future1 = connection.subscribe("SomeTestChannel", {}, null);
        transport.add(
            '{"type":"confirm_subscription","identifier":"{\\"channel\\":\\"SomeTestChannel\\"}"}');
        await Future.delayed(Duration.zero);
        (await future1).cancel();

        final future2 = connection.subscribe("SomeTestChannel", {}, null);
        transport.add(
            '{"type":"confirm_subscription","identifier":"{\\"channel\\":\\"SomeTestChannel\\"}"}');
        await Future.delayed(Duration.zero);
        expect(await future2, isA<AsyncCableChannel>());

        verify(() => mockWebSocket.add(
                '{"command":"subscribe","identifier":"{\\"channel\\":\\"SomeTestChannel\\"}"}'))
            .called(2);
      });

      test(
          'completes with an error if the connection is closed by an error before the subscription is confirmed',
          () async {
        final future = connection.subscribe("SomeTestChannel", {}, null);
        verify(() => mockWebSocket.add(
            '{"command":"subscribe","identifier":"{\\"channel\\":\\"SomeTestChannel\\"}"}'));

        expect(future, throwsA(isA<AsyncCableServerRestart>()));
        transport.add(
            json.encode({"type": "disconnect", "reason": "server_restart"}));
        await Future.delayed(Duration.zero);
      });

      test(
          'completes with an error if the connection is closed by an error before the subscription is confirmed',
          () async {
        final future = connection.subscribe("SomeTestChannel", {}, null);
        verify(() => mockWebSocket.add(
            '{"command":"subscribe","identifier":"{\\"channel\\":\\"SomeTestChannel\\"}"}'));

        expect(future, throwsA(isA<StateError>()));
        connection.close();
      });

      test(
          'completes with an error if the connection was already closed by an error',
          () async {
        mockWebSocket.close();
        await Future.delayed(Duration.zero);
        expect(connection.isClosed, true);

        final future = connection.subscribe("SomeTestChannel", {}, null);
        expect(future, throwsA(isA<AsyncCableServerClosedConnection>()));
      });

      test(
          'completes with an error if the connection was already closed explicitly',
          () async {
        connection.close();
        expect(connection.isClosed, true);

        final future = connection.subscribe("SomeTestChannel", {}, null);
        expect(future, throwsA(isA<StateError>()));
      });

      test('is immediately rejected if the connection name is invalid',
          () async {
        expect(() => connection.subscribe("SomeTest", {}, null),
            throwsA(isA<UnsupportedError>()));
      });
    });

    group('subscribed channels', () {
      late AsyncCableChannel channel;
      List<dynamic> deliveredMessages = [];
      dynamic deliveredError;

      setUp(() async {
        deliveredMessages = [];
        deliveredError = null;
        final future = connection.subscribe(
            "SomeTestChannel", {}, (message) => deliveredMessages.add(message),
            onError: (error) => deliveredError = error);
        transport.add(
            '{"type":"confirm_subscription","identifier":"{\\"channel\\":\\"SomeTestChannel\\"}"}');
        channel = await future;
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
        expect(channel.isConnectionClosed, false);
      });

      test('delivers connection errors as channel stream errors', () async {
        transport.add(
            json.encode({"type": "disconnect", "reason": "server_restart"}));
        await Future.delayed(Duration.zero);

        expect(deliveredError, isA<AsyncCableServerRestart>());
        expect(channel.isConnectionClosed, true);
      });

      test(
          'closes the channel stream without error if the connection is explicitly closed',
          () async {
        connection.close();

        await Future.delayed(Duration.zero);
        expect(deliveredError, isNull);
        expect(channel.isConnectionClosed, true);
      });

      test(
          'closes the channel stream without error if the channel subscription is explicitly cancelled using the channel object',
          () async {
        channel.cancel();

        await Future.delayed(Duration.zero);
        expect(deliveredError, isNull);
        verify(() => mockWebSocket.add(
            '{"command":"unsubscribe","identifier":"{\\"channel\\":\\"SomeTestChannel\\"}"}'));
        expect(channel.isConnectionClosed, false);
      });

      test(
          'closes the channel stream without error if the channel subscription is explicitly cancelled using the subscription object',
          () async {
        channel.subscription.cancel();

        await Future.delayed(Duration.zero);
        expect(deliveredError, isNull);
        verify(() => mockWebSocket.add(
            '{"command":"unsubscribe","identifier":"{\\"channel\\":\\"SomeTestChannel\\"}"}'));
        expect(channel.isConnectionClosed, false);
      });

      test(
          'only unsubscribes when all subscriptions to the channel have been cancelled',
          () async {
        final second = await connection.subscribe(
            "SomeTestChannel", {}, (message) => deliveredMessages.add(message),
            onError: (error) => deliveredError = error);
        verify(() => mockWebSocket.add(
                '{"command":"subscribe","identifier":"{\\"channel\\":\\"SomeTestChannel\\"}"}'))
            .called(1);

        channel.subscription.cancel();
        await Future.delayed(Duration.zero);
        verifyNever(() => mockWebSocket.add(
            '{"command":"unsubscribe","identifier":"{\\"channel\\":\\"SomeTestChannel\\"}"}'));

        second.cancel();
        await Future.delayed(Duration.zero);
        expect(deliveredError, isNull);
        verify(() => mockWebSocket.add(
            '{"command":"unsubscribe","identifier":"{\\"channel\\":\\"SomeTestChannel\\"}"}'));

        expect(channel.isConnectionClosed, false);
      });
    });
  });
}
