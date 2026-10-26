import 'package:flutter/foundation.dart';

/// A message the user sent to the agent (fetched by polling the inbox).
@immutable
class InboundMessage {
  const InboundMessage({
    required this.id,
    required this.text,
    this.from,
    this.timestamp,
  });

  /// Stable id supplied by the agent; used to avoid answering twice.
  final String id;
  final String text;

  /// Sender in whatever format the agent uses (usually digits only).
  final String? from;
  final DateTime? timestamp;

  /// Digits of [from], for tolerant comparison with the configured number.
  String? get fromDigits => normalizeNumber(from);

  static String? normalizeNumber(String? raw) {
    if (raw == null) return null;
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    return digits.isEmpty ? null : digits;
  }

  /// Accepts the common JSON shapes agents use. Returns `null` when the entry
  /// cannot be understood (it is then skipped, not treated as an error).
  ///
  /// Recognised keys:
  /// * id: `id`, `message_id`, `messageId`, `sid`, `wamid`
  /// * sender: `from`, `sender`, `phone`, `number`, `wa_id`
  /// * text: `text` (string or `{ "body": … }`), `body`, `message`, `content`
  /// * time: `timestamp`, `created_at`, `createdAt`, `date`, `time`
  ///   (ISO-8601 string, epoch seconds or epoch milliseconds)
  static InboundMessage? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final map = raw.cast<Object?, Object?>();

    final text = _text(map);
    if (text == null) return null;

    final id = _string(map, const ['id', 'message_id', 'messageId', 'sid', 'wamid']);
    final from = _string(map, const ['from', 'sender', 'phone', 'number', 'wa_id']);
    final timestamp = parseTimestamp(
      _first(map, const ['timestamp', 'created_at', 'createdAt', 'date', 'time']),
    );

    return InboundMessage(
      id: id ?? _syntheticId(from, text, timestamp),
      text: text,
      from: from,
      timestamp: timestamp,
    );
  }

  /// Accepts a bare list, or an object wrapping it under `messages`, `data`,
  /// `items`, `results` or `inbox`.
  static List<InboundMessage> parseList(Object? body) {
    Object? list = body;
    if (body is Map) {
      final map = body.cast<Object?, Object?>();
      list = _first(map, const ['messages', 'data', 'items', 'results', 'inbox']);
      // {"data": {"messages": [...]}}
      if (list is Map) {
        list = _first(list.cast<Object?, Object?>(), const [
          'messages',
          'items',
          'results',
        ]);
      }
    }
    if (list is! List) return const [];
    return [for (final entry in list) ?tryParse(entry)];
  }

  static DateTime? parseTimestamp(Object? raw) {
    if (raw == null) return null;
    if (raw is num) {
      final value = raw.toInt();
      // Heuristic: epoch seconds are < 10^11 until the year 5138.
      final millis = value.abs() < 100000000000 ? value * 1000 : value;
      return DateTime.fromMillisecondsSinceEpoch(millis);
    }
    if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) return null;
      final asNumber = int.tryParse(trimmed);
      if (asNumber != null) return parseTimestamp(asNumber);
      return DateTime.tryParse(trimmed);
    }
    return null;
  }

  // ---------------------------------------------------------------------------

  static String? _text(Map<Object?, Object?> map) {
    for (final key in const ['text', 'body', 'message', 'content']) {
      final value = map[key];
      if (value is String && value.trim().isNotEmpty) return value;
      if (value is Map) {
        final inner = value.cast<Object?, Object?>();
        for (final innerKey in const ['body', 'text', 'content']) {
          final innerValue = inner[innerKey];
          if (innerValue is String && innerValue.trim().isNotEmpty) {
            return innerValue;
          }
        }
      }
    }
    return null;
  }

  static Object? _first(Map<Object?, Object?> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value != null) return value;
    }
    return null;
  }

  static String? _string(Map<Object?, Object?> map, List<String> keys) {
    final value = _first(map, keys);
    if (value == null) return null;
    final text = '$value'.trim();
    return text.isEmpty ? null : text;
  }

  static String _syntheticId(String? from, String text, DateTime? timestamp) =>
      'synthetic:${from ?? ''}:${timestamp?.millisecondsSinceEpoch ?? ''}:'
      '${text.hashCode}';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InboundMessage &&
          other.id == id &&
          other.text == text &&
          other.from == from &&
          other.timestamp == timestamp;

  @override
  int get hashCode => Object.hash(id, text, from, timestamp);

  @override
  String toString() =>
      'InboundMessage($id, from: $from, at: $timestamp, "$text")';
}
