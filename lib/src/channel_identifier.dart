import 'dart:collection';
import 'dart:convert';

class ChannelIdentifier {
  static String encode(String channelName, Map<String, dynamic> params) {
    // Sort the params to ensure that we can repeatably produce the ID.
    final map = SplayTreeMap.from(params);
    map["channel"] = channelName;
    return jsonEncode(map);
  }

  static String normalize(String identifier) {
    final map = SplayTreeMap.from(jsonDecode(identifier));
    return jsonEncode(map);
  }
}
