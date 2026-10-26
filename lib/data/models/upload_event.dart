import 'package:flutter/foundation.dart';

import 'enums.dart';

/// Column names of the `upload_events` table.
abstract final class EventColumns {
  static const String table = 'upload_events';

  static const String id = 'id';
  static const String uploadId = 'upload_id';
  static const String timestamp = 'timestamp';
  static const String level = 'level';
  static const String message = 'message';
}

/// One line in the activity log of a [ScheduledUpload]
/// ("Scheduled", "WhatsApp notification sent", "YouTube upload failed: …").
@immutable
class UploadEvent {
  UploadEvent({
    this.id,
    required this.uploadId,
    required this.message,
    this.level = EventLevel.info,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  final int? id;
  final int uploadId;
  final DateTime timestamp;
  final EventLevel level;
  final String message;

  Map<String, Object?> toMap() => {
    EventColumns.id: id,
    EventColumns.uploadId: uploadId,
    EventColumns.timestamp: timestamp.millisecondsSinceEpoch,
    EventColumns.level: level.dbValue,
    EventColumns.message: message,
  };

  factory UploadEvent.fromMap(Map<String, Object?> map) => UploadEvent(
    id: map[EventColumns.id] as int?,
    uploadId: (map[EventColumns.uploadId] as num).toInt(),
    timestamp: DateTime.fromMillisecondsSinceEpoch(
      (map[EventColumns.timestamp] as num?)?.toInt() ?? 0,
    ),
    level: EventLevel.fromDb(map[EventColumns.level] as String?),
    message: map[EventColumns.message] as String? ?? '',
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UploadEvent &&
          other.id == id &&
          other.uploadId == uploadId &&
          other.timestamp == timestamp &&
          other.level == level &&
          other.message == message;

  @override
  int get hashCode => Object.hash(id, uploadId, timestamp, level, message);

  @override
  String toString() =>
      'UploadEvent(upload: $uploadId, ${level.dbValue}: $message)';
}
