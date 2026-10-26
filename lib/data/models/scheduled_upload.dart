import 'package:flutter/foundation.dart';

import 'enums.dart';

/// Sentinel used by [ScheduledUpload.copyWith] to distinguish "not provided"
/// from an explicit `null` for nullable fields.
const Object _unset = Object();

/// Column names of the `scheduled_uploads` table.
abstract final class UploadColumns {
  static const String table = 'scheduled_uploads';

  static const String id = 'id';
  static const String videoPath = 'video_path';
  static const String videoName = 'video_name';
  static const String videoSizeBytes = 'video_size_bytes';
  static const String title = 'title';
  static const String description = 'description';
  static const String tags = 'tags';
  static const String scheduledTime = 'scheduled_time';
  static const String status = 'status';
  static const String platform = 'platform';
  static const String youtubeStatus = 'youtube_status';
  static const String instagramStatus = 'instagram_status';
  static const String youtubeVideoId = 'youtube_video_id';
  static const String instagramMediaId = 'instagram_media_id';
  static const String uploadProgress = 'upload_progress';
  static const String errorMessage = 'error_message';
  static const String retryCount = 'retry_count';
  static const String createdAt = 'created_at';
  static const String updatedAt = 'updated_at';
}

/// A video waiting on the device to be uploaded at [scheduledTime].
@immutable
class ScheduledUpload {
  ScheduledUpload({
    this.id,
    required this.videoPath,
    required this.videoName,
    this.videoSizeBytes = 0,
    required this.title,
    this.description = '',
    List<String> tags = const [],
    required this.scheduledTime,
    this.status = UploadStatus.scheduled,
    this.platform = UploadPlatform.both,
    this.youtubeStatus = PlatformUploadStatus.pending,
    this.instagramStatus = PlatformUploadStatus.pending,
    this.youtubeVideoId,
    this.instagramMediaId,
    this.uploadProgress = 0,
    this.errorMessage,
    this.retryCount = 0,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : tags = List.unmodifiable(normalizeTags(tags)),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? createdAt ?? DateTime.now();

  /// Convenience constructor for a brand new schedule. Per-platform statuses
  /// are derived from [platform].
  factory ScheduledUpload.create({
    required String videoPath,
    required String videoName,
    required int videoSizeBytes,
    required String title,
    required String description,
    required List<String> tags,
    required DateTime scheduledTime,
    required UploadPlatform platform,
  }) {
    final now = DateTime.now();
    return ScheduledUpload(
      videoPath: videoPath,
      videoName: videoName,
      videoSizeBytes: videoSizeBytes,
      title: title.trim(),
      description: description.trim(),
      tags: tags,
      scheduledTime: scheduledTime,
      platform: platform,
      youtubeStatus: platform.includesYouTube
          ? PlatformUploadStatus.pending
          : PlatformUploadStatus.notApplicable,
      instagramStatus: platform.includesInstagram
          ? PlatformUploadStatus.pending
          : PlatformUploadStatus.notApplicable,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// Database primary key (`null` until inserted).
  final int? id;

  /// Absolute path of the video inside the app's private storage.
  final String videoPath;

  /// Original file name shown to the user.
  final String videoName;

  final int videoSizeBytes;

  final String title;
  final String description;

  /// Normalised, de-duplicated tag list (stored comma-separated).
  final List<String> tags;

  /// Local wall-clock time at which the upload should start.
  final DateTime scheduledTime;

  final UploadStatus status;
  final UploadPlatform platform;

  final PlatformUploadStatus youtubeStatus;
  final PlatformUploadStatus instagramStatus;

  /// Remote identifiers once published.
  final String? youtubeVideoId;
  final String? instagramMediaId;

  /// Overall progress 0..1 (updated by the uploaders).
  final double uploadProgress;

  /// Last error, when [status] is [UploadStatus.failed].
  final String? errorMessage;

  final int retryCount;

  final DateTime createdAt;
  final DateTime updatedAt;

  // --- Derived helpers -------------------------------------------------------

  /// `true` once the scheduled time has passed and the upload has not started.
  bool isDue([DateTime? now]) =>
      status == UploadStatus.scheduled &&
      !scheduledTime.isAfter(now ?? DateTime.now());

  Duration timeUntil([DateTime? now]) =>
      scheduledTime.difference(now ?? DateTime.now());

  /// Tags as the comma-separated string stored in SQLite.
  String get tagsAsString => tags.join(', ');

  /// Line reported back over WhatsApp when the user asks for "Status".
  String get statusSummary =>
      'YouTube: ${youtubeStatus.label} | Instagram: ${instagramStatus.label}';

  // --- (De)serialisation -----------------------------------------------------

  Map<String, Object?> toMap() => {
    UploadColumns.id: id,
    UploadColumns.videoPath: videoPath,
    UploadColumns.videoName: videoName,
    UploadColumns.videoSizeBytes: videoSizeBytes,
    UploadColumns.title: title,
    UploadColumns.description: description,
    UploadColumns.tags: tags.join(','),
    UploadColumns.scheduledTime: scheduledTime.millisecondsSinceEpoch,
    UploadColumns.status: status.dbValue,
    UploadColumns.platform: platform.dbValue,
    UploadColumns.youtubeStatus: youtubeStatus.dbValue,
    UploadColumns.instagramStatus: instagramStatus.dbValue,
    UploadColumns.youtubeVideoId: youtubeVideoId,
    UploadColumns.instagramMediaId: instagramMediaId,
    UploadColumns.uploadProgress: uploadProgress,
    UploadColumns.errorMessage: errorMessage,
    UploadColumns.retryCount: retryCount,
    UploadColumns.createdAt: createdAt.millisecondsSinceEpoch,
    UploadColumns.updatedAt: updatedAt.millisecondsSinceEpoch,
  };

  factory ScheduledUpload.fromMap(Map<String, Object?> map) {
    return ScheduledUpload(
      id: map[UploadColumns.id] as int?,
      videoPath: map[UploadColumns.videoPath] as String? ?? '',
      videoName: map[UploadColumns.videoName] as String? ?? '',
      videoSizeBytes: (map[UploadColumns.videoSizeBytes] as num?)?.toInt() ?? 0,
      title: map[UploadColumns.title] as String? ?? '',
      description: map[UploadColumns.description] as String? ?? '',
      tags: parseTags(map[UploadColumns.tags] as String?),
      scheduledTime: DateTime.fromMillisecondsSinceEpoch(
        (map[UploadColumns.scheduledTime] as num?)?.toInt() ?? 0,
      ),
      status: UploadStatus.fromDb(map[UploadColumns.status] as String?),
      platform: UploadPlatform.fromDb(map[UploadColumns.platform] as String?),
      youtubeStatus: PlatformUploadStatus.fromDb(
        map[UploadColumns.youtubeStatus] as String?,
      ),
      instagramStatus: PlatformUploadStatus.fromDb(
        map[UploadColumns.instagramStatus] as String?,
      ),
      youtubeVideoId: map[UploadColumns.youtubeVideoId] as String?,
      instagramMediaId: map[UploadColumns.instagramMediaId] as String?,
      uploadProgress:
          (map[UploadColumns.uploadProgress] as num?)?.toDouble() ?? 0,
      errorMessage: map[UploadColumns.errorMessage] as String?,
      retryCount: (map[UploadColumns.retryCount] as num?)?.toInt() ?? 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (map[UploadColumns.createdAt] as num?)?.toInt() ?? 0,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (map[UploadColumns.updatedAt] as num?)?.toInt() ?? 0,
      ),
    );
  }

  ScheduledUpload copyWith({
    int? id,
    String? videoPath,
    String? videoName,
    int? videoSizeBytes,
    String? title,
    String? description,
    List<String>? tags,
    DateTime? scheduledTime,
    UploadStatus? status,
    UploadPlatform? platform,
    PlatformUploadStatus? youtubeStatus,
    PlatformUploadStatus? instagramStatus,
    Object? youtubeVideoId = _unset,
    Object? instagramMediaId = _unset,
    double? uploadProgress,
    Object? errorMessage = _unset,
    int? retryCount,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return ScheduledUpload(
      id: id ?? this.id,
      videoPath: videoPath ?? this.videoPath,
      videoName: videoName ?? this.videoName,
      videoSizeBytes: videoSizeBytes ?? this.videoSizeBytes,
      title: title ?? this.title,
      description: description ?? this.description,
      tags: tags ?? this.tags,
      scheduledTime: scheduledTime ?? this.scheduledTime,
      status: status ?? this.status,
      platform: platform ?? this.platform,
      youtubeStatus: youtubeStatus ?? this.youtubeStatus,
      instagramStatus: instagramStatus ?? this.instagramStatus,
      youtubeVideoId: identical(youtubeVideoId, _unset)
          ? this.youtubeVideoId
          : youtubeVideoId as String?,
      instagramMediaId: identical(instagramMediaId, _unset)
          ? this.instagramMediaId
          : instagramMediaId as String?,
      uploadProgress: uploadProgress ?? this.uploadProgress,
      errorMessage: identical(errorMessage, _unset)
          ? this.errorMessage
          : errorMessage as String?,
      retryCount: retryCount ?? this.retryCount,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  // --- Tag helpers -----------------------------------------------------------

  /// Splits a comma-separated user input into clean tags.
  static List<String> parseTags(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    return normalizeTags(raw.split(','));
  }

  /// Trims, drops empties and removes case-insensitive duplicates while
  /// keeping the first occurrence's order.
  static List<String> normalizeTags(Iterable<String> tags) {
    final seen = <String>{};
    final result = <String>[];
    for (final tag in tags) {
      final cleaned = tag.trim();
      if (cleaned.isEmpty) continue;
      if (seen.add(cleaned.toLowerCase())) result.add(cleaned);
    }
    return result;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ScheduledUpload &&
        other.id == id &&
        other.videoPath == videoPath &&
        other.videoName == videoName &&
        other.videoSizeBytes == videoSizeBytes &&
        other.title == title &&
        other.description == description &&
        listEquals(other.tags, tags) &&
        other.scheduledTime == scheduledTime &&
        other.status == status &&
        other.platform == platform &&
        other.youtubeStatus == youtubeStatus &&
        other.instagramStatus == instagramStatus &&
        other.youtubeVideoId == youtubeVideoId &&
        other.instagramMediaId == instagramMediaId &&
        other.uploadProgress == uploadProgress &&
        other.errorMessage == errorMessage &&
        other.retryCount == retryCount;
  }

  @override
  int get hashCode => Object.hash(
    id,
    videoPath,
    videoName,
    videoSizeBytes,
    title,
    description,
    Object.hashAll(tags),
    scheduledTime,
    status,
    platform,
    youtubeStatus,
    instagramStatus,
    youtubeVideoId,
    instagramMediaId,
    uploadProgress,
    errorMessage,
    retryCount,
  );

  @override
  String toString() =>
      'ScheduledUpload(id: $id, title: "$title", platform: ${platform.dbValue}, '
      'status: ${status.dbValue}, scheduledTime: $scheduledTime)';
}
