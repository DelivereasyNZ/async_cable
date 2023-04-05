import 'package:async_cable/async_cable.dart';

String yourAuthToken() {
  return "your token goes here";
}

void main() async {
  final accessToken = yourAuthToken();
  final connection = await AsyncCable.connect(
    "ws://localhost:3000/cable",
    headers: {
      "Origin": "http://localhost:3000",
      "Authorization": "Bearer $accessToken",
    },
  );
  final channel = connection.channel("HelloChannel", {"foo": "bar"});
  channel.messages.listen(
    (message) => print("Received ${message.message["greeting"]}"),
    cancelOnError: true,
  );
  channel.perform("hello", {"greeting": "hi"});
}
