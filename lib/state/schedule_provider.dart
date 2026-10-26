import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../core/utils/formatters.dart';
import '../data/models/enums.dart';
import '../data/models/scheduled_upload.dart';
import '../data/models/upload_event.dart';
import '../data/repositories/schedule_repository.dart';
import '../services/video_file_service.dart';

/// UI-facing state for the list of scheduled uploads.
class ScheduleProvider extends ChangeNotifier {
  ScheduleProvider({
    required ScheduleRepository repository,
    required VideoFileService videoFiles,
  }) : _repository = repository,
       _videoFiles = videoFiles;

  final ScheduleRepository _repository;
  final VideoFileService _videoFiles;

  List<ScheduledUpload> _uploads = const [];
  bool _isLoading = true;
  String? _error;

  List<ScheduledUpload> get uploads => _uploads;
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// Scheduled / in-flight uploads, earliest first.
  List<ScheduledUpload> get upcoming => _uploads
      .where((u) => !u.status.isTerminal)
      .toList(growable: false)
    ..sort((a, b) => a.scheduledTime.compareTo(b.scheduledTime));

  /// Completed / failed uploads, most recent first.
  List<ScheduledUpload> get history => _uploads
      .where((u) => u.status.isTerminal)
      .toList(growable: false)
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  ScheduledUpload? byId(int id) {
    for (final upload in _uploads) {
      if (upload.id == id) return upload;
    }
    return null;
  }

  /// Reloads everything from the database.
  Future<void> load() async {
    try {
      _uploads = await _repository.getAll();
      _error = null;
    } catch (e) {
      _error = 'Could not load schedule: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Copies the picked [video] into private storage and stores the schedule.
  Future<ScheduledUpload> schedule({
    required PlatformFile video,
    required String title,
    required String description,
    required List<String> tags,
    required DateTime scheduledTime,
    required UploadPlatform platform,
    ProgressCallback? onCopyProgress,
  }) async {
    final persisted = await _videoFiles.persist(
      video,
      onProgress: onCopyProgress,
    );
    try {
      final created = await _repository.create(
        ScheduledUpload.create(
          videoPath: persisted.path,
          videoName: persisted.name,
          videoSizeBytes: persisted.sizeBytes,
          title: title,
          description: description,
          tags: tags,
          scheduledTime: scheduledTime,
          platform: platform,
        ),
      );
      await _repository.logEvent(
        created.id!,
        'Scheduled for ${Formatters.dateTime(scheduledTime)} '
        '(${platform.label}). Video kept on device: ${persisted.name} '
        '(${Formatters.bytes(persisted.sizeBytes)}).',
      );
      await load();
      return created;
    } catch (_) {
      // Don't leave an orphaned copy behind if the DB insert failed.
      await _videoFiles.deleteManagedFile(persisted.path);
      rethrow;
    }
  }

  /// Saves edited metadata/schedule. If [newVideo] is supplied the old private
  /// copy is replaced. A failed upload that gets edited is re-armed.
  Future<ScheduledUpload> edit(
    ScheduledUpload original, {
    required String title,
    required String description,
    required List<String> tags,
    required DateTime scheduledTime,
    required UploadPlatform platform,
    PlatformFile? newVideo,
    ProgressCallback? onCopyProgress,
  }) async {
    PersistedVideo? persisted;
    if (newVideo != null) {
      persisted = await _videoFiles.persist(newVideo, onProgress: onCopyProgress);
    }

    final updated = original.copyWith(
      title: title.trim(),
      description: description.trim(),
      tags: tags,
      scheduledTime: scheduledTime,
      platform: platform,
      videoPath: persisted?.path,
      videoName: persisted?.name,
      videoSizeBytes: persisted?.sizeBytes,
      // Editing always re-arms the schedule.
      status: UploadStatus.scheduled,
      youtubeStatus: platform.includesYouTube
          ? PlatformUploadStatus.pending
          : PlatformUploadStatus.notApplicable,
      instagramStatus: platform.includesInstagram
          ? PlatformUploadStatus.pending
          : PlatformUploadStatus.notApplicable,
      uploadProgress: 0,
      errorMessage: null,
      youtubeVideoId: null,
      instagramMediaId: null,
    );

    try {
      await _repository.update(updated);
    } catch (_) {
      if (persisted != null) {
        await _videoFiles.deleteManagedFile(persisted.path);
      }
      rethrow;
    }

    if (persisted != null && original.videoPath != persisted.path) {
      await _videoFiles.deleteManagedFile(original.videoPath);
    }
    await _repository.logEvent(
      updated.id!,
      'Edited. Now scheduled for ${Formatters.dateTime(scheduledTime)} '
      '(${platform.label})${persisted != null ? ', video replaced' : ''}.',
    );
    await load();
    return updated;
  }

  /// Re-arms a failed (or completed) upload for a new time.
  Future<void> reschedule(ScheduledUpload upload, DateTime newTime) async {
    final id = upload.id;
    if (id == null) return;
    await _repository.updateStatus(
      id,
      status: UploadStatus.scheduled,
      youtubeStatus: upload.platform.includesYouTube
          ? PlatformUploadStatus.pending
          : PlatformUploadStatus.notApplicable,
      instagramStatus: upload.platform.includesInstagram
          ? PlatformUploadStatus.pending
          : PlatformUploadStatus.notApplicable,
      uploadProgress: 0,
      clearErrorMessage: true,
      incrementRetryCount: upload.status == UploadStatus.failed,
    );
    await _repository.update(
      (await _repository.getById(id) ?? upload).copyWith(scheduledTime: newTime),
    );
    await _repository.logEvent(
      id,
      'Rescheduled for ${Formatters.dateTime(newTime)}.',
    );
    await load();
  }

  /// Removes the schedule and its private video copy.
  Future<void> delete(ScheduledUpload upload) async {
    final id = upload.id;
    if (id == null) return;
    await _repository.delete(id);
    await _videoFiles.deleteManagedFile(upload.videoPath);
    _uploads = _uploads.where((u) => u.id != id).toList(growable: false);
    notifyListeners();
  }

  Future<List<UploadEvent>> eventsFor(int uploadId) =>
      _repository.getEvents(uploadId);

  Future<bool> videoExists(ScheduledUpload upload) =>
      _videoFiles.exists(upload.videoPath);
}
