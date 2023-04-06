# AsyncCable

Async/stream-oriented implementation of the Rails ActionCable protocol for Dart & Flutter.

## Features

Supports ActionCable over `dart:io` WebSocket connections.

Web (`dart:html`) is not supported, and support is not planned at this time.

## Getting started

To use this library with unauthenticated ActionCable servers, you just need to know the URL.

Most ActionCable servers use authentication. To use these, you first need to figure out how your Dart application will authenticate to the Rails server. For example, if you will use `Authorization` headers, you may implement your own APIs to get an authentication token, then pass it in the [AsyncCable.connect] `headers` option, and make sure the `ApplicationCable::Connection` code in the server will accept these authorization headers.

Then you just need to agree on the channel naming and parameter conventions with the server code, and you're ready to start sending & receiving messages.

## Usage

```dart
void main() async {
  final accessToken = yourAuthToken();
  final connection = await AsyncCable.connect(
    "ws://localhost:3000/cable",
    headers: {
      "Origin": "http://localhost:3000",
      "Authorization": "Bearer $accessToken",
    },
  );
  final channel = await connection.subscribe(
    "HelloChannel",
    {"foo": "bar"},
    (message) => print("Received ${message.message["greeting"]}"),
  );
  channel.perform("hello", {"greeting": "hi"});
}
```

## Additional information

Copyright (c) Delivereasy Ltd., 2023.
