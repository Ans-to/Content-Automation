import 'package:content_automation/data/models/enums.dart';
import 'package:content_automation/data/models/scheduled_upload.dart';
import 'package:content_automation/data/models/upload_event.dart';
import 'package:content_automation/data/repositories/schedule_repository.dart';

/// Pure-Dart [ScheduleRepository] for widget tests (no isolates, no SQLite).
class InMemoryScheduleRepository implements ScheduleRepository {
  final Map<int, ScheduledUpload> _uploads = {};
  final List<UploadEvent> _events = [];
  int _nextUploadId = 1;
  int _nextEventId = 1;

  @override
  Future<ScheduledUpload> create(ScheduledUpload upload) async {
    final created = upload.copyWith(id: _nextUploadId++);
    _uploads[created.id!] = created;
    return created;
  }

  @override
  Future<void> update(ScheduledUpload upload) async {
    _uploads[upload.id!] = upload;
  }

  @override
  Future<void> delete(int id) async {
    _uploads.remove(id);
    _events.removeWhere((e) => e.uploadId == id);
  }

  @override
  Future<ScheduledUpload?> getById(int id) async => _uploads[id];

  @override
  Future<List<ScheduledUpload>> getAll() async =>
      _uploads.values.toList()
        ..sort((a, b) => a.scheduledTime.compareTo(b.scheduledTime));

  @override
  Future<List<ScheduledUpload>> getByStatus(UploadStatus status) async =>
      (await getAll()).where((u) => u.status == status).toList();

  @override
  Future<List<ScheduledUpload>> getDue({DateTime? now}) async {
    final reference = now ?? DateTime.now();
    return (await getAll()).where((u) => u.isDue(reference)).toList();
  }

  @override
  Future<List<ScheduledUpload>> getActive() async => (await getAll())
      .where((u) => u.status.isActive)
      .toList();

  @override
  Future<bool> claim(
    int id, {
    required UploadStatus from,
    required UploadStatus to,
  }) async {
    final current = _uploads[id];
    if (current == null || current.status != from) return false;
    _uploads[id] = current.copyWith(status: to, updatedAt: DateTime.now());
    return true;
  }

  @override
  Future<ScheduledUpload?> getNextScheduled({DateTime? now}) async {
    final reference = now ?? DateTime.now();
    for (final upload in await getAll()) {
      if (upload.status == UploadStatus.scheduled &&
          upload.scheduledTime.isAfter(reference)) {
        return upload;
      }
    }
    return null;
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
    final current = _uploads[id];
    if (current == null) return;
    _uploads[id] = current.copyWith(
      status: status,
      youtubeStatus: youtubeStatus,
      instagramStatus: instagramStatus,
      uploadProgress: uploadProgress,
      youtubeVideoId: youtubeVideoId ?? current.youtubeVideoId,
      instagramMediaId: instagramMediaId ?? current.instagramMediaId,
      errorMessage: clearErrorMessage
          ? null
          : (errorMessage ?? current.errorMessage),
      retryCount: incrementRetryCount
          ? current.retryCount + 1
          : current.retryCount,
      updatedAt: DateTime.now(),
    );
  }

  @override
  Future<UploadEvent> logEvent(
    int uploadId,
    String message, {
    EventLevel level = EventLevel.info,
  }) async {
    final event = UploadEvent(
      id: _nextEventId++,
      uploadId: uploadId,
      message: message,
      level: level,
    );
    _events.add(event);
    return event;
  }

  @override
  Future<List<UploadEvent>> getEvents(int uploadId, {int limit = 200}) async =>
      _events.where((e) => e.uploadId == uploadId).toList().reversed.take(limit).toList();
}
