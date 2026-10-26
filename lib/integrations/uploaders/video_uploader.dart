import '../../data/models/enums.dart';
import '../../data/models/scheduled_upload.dart';
import '../../services/settings_service.dart';

/// Reports 0..1 progress while bytes are being sent.
typedef UploadProgressCallback = void Function(double progress);

/// Appends a line to the upload's activity log.
typedef UploadLogger = Future<void> Function(String message);

/// Persists opaque resume data for the platform (e.g. the YouTube resumable
/// session URI) so an interrupted upload can continue after the process was
/// killed. `null` clears it once the transfer is finished.
typedef UploadSessionSaver = Future<void> Function(String? session);

/// Result of a single platform upload.
class UploadOutcome {
  const UploadOutcome.success({this.remoteId})
    : succeeded = true,
      error = null;

  const UploadOutcome.failure(String this.error)
    : succeeded = false,
      remoteId = null;

  final bool succeeded;

  /// YouTube video id / Instagram media id.
  final String? remoteId;

  /// Human readable reason (shown in the UI and sent to WhatsApp).
  final String? error;
}

/// One destination (YouTube in Phase 4, Instagram in Phase 5).
abstract interface class VideoUploader {
  /// Which of the two platforms this uploader serves.
  UploadPlatform get platform;

  /// Uploads [upload]'s local video file with its metadata.
  ///
  /// Implementations must not throw for expected failures; return
  /// [UploadOutcome.failure] instead. Unexpected exceptions are caught by the
  /// engine and treated as failures too.
  ///
  /// [saveSession] stores resume data between chunks; when the engine retries
  /// an interrupted upload the stored value is available again through the
  /// [ScheduledUpload] (see [ScheduledUpload.youtubeUploadUri]).
  Future<UploadOutcome> upload(
    ScheduledUpload upload, {
    required AppSettings settings,
    required UploadProgressCallback onProgress,
    required UploadLogger log,
    required UploadSessionSaver saveSession,
  });
}

/// Stand-in until the real uploader for [platform] lands; fails with a clear
/// message so the pipeline (trigger → notify → status → WhatsApp) can already
/// be exercised end-to-end.
class UnavailableUploader implements VideoUploader {
  const UnavailableUploader(this.platform, {required this.arrivesIn});

  @override
  final UploadPlatform platform;

  /// e.g. "Phase 5".
  final String arrivesIn;

  @override
  Future<UploadOutcome> upload(
    ScheduledUpload upload, {
    required AppSettings settings,
    required UploadProgressCallback onProgress,
    required UploadLogger log,
    required UploadSessionSaver saveSession,
  }) async {
    await log(
      '${platform.label} uploader is not part of this build yet ($arrivesIn).',
    );
    return UploadOutcome.failure(
      '${platform.label} uploader not available in this build ($arrivesIn).',
    );
  }
}
