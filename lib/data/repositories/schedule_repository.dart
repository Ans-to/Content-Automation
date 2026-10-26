import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';
import '../models/enums.dart';
import '../models/scheduled_upload.dart';
import '../models/upload_event.dart';

/// Persistence boundary for scheduled uploads and their activity log.
///
/// The UI, the background scheduler (Phase 2), the WhatsApp status responder
/// (Phase 3) and the uploaders (Phases 4/5) all talk to this interface.
abstract interface class ScheduleRepository {
  /// Inserts [upload] and returns it with its new [ScheduledUpload.id].
  Future<ScheduledUpload> create(ScheduledUpload upload);

  /// Overwrites every column of [upload] (requires an id).
  Future<void> update(ScheduledUpload upload);

  /// Deletes the upload and (via cascade) its events.
  Future<void> delete(int id);

  Future<ScheduledUpload?> getById(int id);

  /// All uploads ordered by scheduled time (earliest first).
  Future<List<ScheduledUpload>> getAll();

  Future<List<ScheduledUpload>> getByStatus(UploadStatus status);

  /// Uploads still in [UploadStatus.scheduled] whose time is `<= now`.
  Future<List<ScheduledUpload>> getDue({DateTime? now});

  /// The earliest upload still waiting in the future (used to arm alarms).
  Future<ScheduledUpload?> getNextScheduled({DateTime? now});

  /// Partial status update used by the scheduler and uploaders.
  Future<void> updateStatus(
    int id, {
    UploadStatus? status,
    PlatformUploadStatus? youtubeStatus,
    PlatformUploadStatus? instagramStatus,
    double? uploadProgress,
    String? youtubeVideoId,
    String? instagramMediaId,
    String? errorMessage,
    bool clearErrorMessage = false,
    bool incrementRetryCount = false,
  });

  /// Appends a line to the upload's activity log.
  Future<UploadEvent> logEvent(
    int uploadId,
    String message, {
    EventLevel level = EventLevel.info,
  });

  /// Newest events first.
  Future<List<UploadEvent>> getEvents(int uploadId, {int limit = 200});
}

/// [ScheduleRepository] backed by sqflite.
class SqliteScheduleRepository implements ScheduleRepository {
  SqliteScheduleRepository(this._database);

  final AppDatabase _database;

  Future<Database> get _db => _database.database;

  @override
  Future<ScheduledUpload> create(ScheduledUpload upload) async {
    final db = await _db;
    final now = DateTime.now();
    final prepared = upload.copyWith(createdAt: now, updatedAt: now);
    final values = prepared.toMap()..remove(UploadColumns.id);
    final id = await db.insert(
      UploadColumns.table,
      values,
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
    return prepared.copyWith(id: id);
  }

  @override
  Future<void> update(ScheduledUpload upload) async {
    final id = upload.id;
    if (id == null) {
      throw ArgumentError('Cannot update an upload that has not been saved.');
    }
    final db = await _db;
    final values = upload.copyWith(updatedAt: DateTime.now()).toMap()
      ..remove(UploadColumns.id);
    await db.update(
      UploadColumns.table,
      values,
      where: '${UploadColumns.id} = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<void> delete(int id) async {
    final db = await _db;
    await db.delete(
      UploadColumns.table,
      where: '${UploadColumns.id} = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<ScheduledUpload?> getById(int id) async {
    final db = await _db;
    final rows = await db.query(
      UploadColumns.table,
      where: '${UploadColumns.id} = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return ScheduledUpload.fromMap(rows.first);
  }

  @override
  Future<List<ScheduledUpload>> getAll() async {
    final db = await _db;
    final rows = await db.query(
      UploadColumns.table,
      orderBy: '${UploadColumns.scheduledTime} ASC, ${UploadColumns.id} ASC',
    );
    return rows.map(ScheduledUpload.fromMap).toList(growable: false);
  }

  @override
  Future<List<ScheduledUpload>> getByStatus(UploadStatus status) async {
    final db = await _db;
    final rows = await db.query(
      UploadColumns.table,
      where: '${UploadColumns.status} = ?',
      whereArgs: [status.dbValue],
      orderBy: '${UploadColumns.scheduledTime} ASC, ${UploadColumns.id} ASC',
    );
    return rows.map(ScheduledUpload.fromMap).toList(growable: false);
  }

  @override
  Future<List<ScheduledUpload>> getDue({DateTime? now}) async {
    final db = await _db;
    final cutoff = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final rows = await db.query(
      UploadColumns.table,
      where:
          '${UploadColumns.status} = ? AND ${UploadColumns.scheduledTime} <= ?',
      whereArgs: [UploadStatus.scheduled.dbValue, cutoff],
      orderBy: '${UploadColumns.scheduledTime} ASC, ${UploadColumns.id} ASC',
    );
    return rows.map(ScheduledUpload.fromMap).toList(growable: false);
  }

  @override
  Future<ScheduledUpload?> getNextScheduled({DateTime? now}) async {
    final db = await _db;
    final cutoff = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final rows = await db.query(
      UploadColumns.table,
      where:
          '${UploadColumns.status} = ? AND ${UploadColumns.scheduledTime} > ?',
      whereArgs: [UploadStatus.scheduled.dbValue, cutoff],
      orderBy: '${UploadColumns.scheduledTime} ASC, ${UploadColumns.id} ASC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return ScheduledUpload.fromMap(rows.first);
  }

  @override
  Future<void> updateStatus(
    int id, {
    UploadStatus? status,
    PlatformUploadStatus? youtubeStatus,
    PlatformUploadStatus? instagramStatus,
    double? uploadProgress,
    String? youtubeVideoId,
    String? instagramMediaId,
    String? errorMessage,
    bool clearErrorMessage = false,
    bool incrementRetryCount = false,
  }) async {
    final values = <String, Object?>{
      UploadColumns.updatedAt: DateTime.now().millisecondsSinceEpoch,
      if (status != null) UploadColumns.status: status.dbValue,
      if (youtubeStatus != null)
        UploadColumns.youtubeStatus: youtubeStatus.dbValue,
      if (instagramStatus != null)
        UploadColumns.instagramStatus: instagramStatus.dbValue,
      if (uploadProgress != null)
        UploadColumns.uploadProgress: uploadProgress.clamp(0.0, 1.0),
      if (youtubeVideoId != null) UploadColumns.youtubeVideoId: youtubeVideoId,
      if (instagramMediaId != null)
        UploadColumns.instagramMediaId: instagramMediaId,
      if (errorMessage != null) UploadColumns.errorMessage: errorMessage,
      if (clearErrorMessage) UploadColumns.errorMessage: null,
    };

    final db = await _db;
    if (incrementRetryCount) {
      // Use raw SQL so the increment is atomic.
      final assignments = values.keys.map((k) => '$k = ?').join(', ');
      await db.rawUpdate(
        'UPDATE ${UploadColumns.table} SET $assignments, '
        '${UploadColumns.retryCount} = ${UploadColumns.retryCount} + 1 '
        'WHERE ${UploadColumns.id} = ?',
        [...values.values, id],
      );
      return;
    }
    await db.update(
      UploadColumns.table,
      values,
      where: '${UploadColumns.id} = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<UploadEvent> logEvent(
    int uploadId,
    String message, {
    EventLevel level = EventLevel.info,
  }) async {
    final db = await _db;
    final event = UploadEvent(uploadId: uploadId, message: message, level: level);
    final values = event.toMap()..remove(EventColumns.id);
    final id = await db.insert(EventColumns.table, values);
    return UploadEvent(
      id: id,
      uploadId: uploadId,
      message: message,
      level: level,
      timestamp: event.timestamp,
    );
  }

  @override
  Future<List<UploadEvent>> getEvents(int uploadId, {int limit = 200}) async {
    final db = await _db;
    final rows = await db.query(
      EventColumns.table,
      where: '${EventColumns.uploadId} = ?',
      whereArgs: [uploadId],
      orderBy: '${EventColumns.timestamp} DESC, ${EventColumns.id} DESC',
      limit: limit,
    );
    return rows.map(UploadEvent.fromMap).toList(growable: false);
  }
}
