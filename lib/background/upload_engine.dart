import 'dart:io';

import '../core/constants.dart';
import '../core/utils/formatters.dart';
import '../data/models/enums.dart';
import '../data/models/scheduled_upload.dart';
import '../data/repositories/schedule_repository.dart';
import '../integrations/uploaders/video_uploader.dart';
import '../integrations/whatsapp/whatsapp_agent.dart';
import '../services/local_notifier.dart';
import '../services/settings_service.dart';

/// What the engine is doing right now (drives the service notification).
class EngineActivity {
  const EngineActivity({
    required this.uploadId,
    required this.title,
    required this.message,
    this.progress,
  });

  final int uploadId;
  final String title;
  final String message;

  /// 0..1 overall progress while uploading, otherwise null.
  final double? progress;
}

/// Runs due uploads: claim → notify → upload per platform → final status.
///
/// Pure Dart; it runs unchanged inside the foreground service, inside a
/// WorkManager task and in unit tests. Safe to run from several isolates at
/// once thanks to [ScheduleRepository.claim].
class UploadEngine {
  UploadEngine({
    required ScheduleRepository repository,
    required SettingsService settingsService,
    required WhatsAppAgent agent,
    required LocalNotifier notifier,
    required Map<UploadPlatform, VideoUploader> uploaders,
    DateTime Function()? clock,
    this.staleTimeout = AppConstants.staleUploadTimeout,
    this.progressWriteInterval = const Duration(milliseconds: 1500),
    this.maxResumeAttempts = AppConstants.maxUploadResumeAttempts,
    bool Function(String path)? fileExists,
  }) : _repository = repository,
       _settingsService = settingsService,
       _agent = agent,
       _notifier = notifier,
       _uploaders = uploaders,
       _clock = clock ?? DateTime.now,
       _fileExists = fileExists ?? _defaultFileExists;

  final ScheduleRepository _repository;
  final SettingsService _settingsService;
  final WhatsAppAgent _agent;
  final LocalNotifier _notifier;
  final Map<UploadPlatform, VideoUploader> _uploaders;
  final DateTime Function() _clock;
  final bool Function(String path) _fileExists;

  /// After this long without any database update an in-flight upload is
  /// considered interrupted.
  final Duration staleTimeout;

  /// Progress rows are written at most this often (uploaders report every
  /// 64 KiB); the row's `updated_at` doubles as the liveness heartbeat.
  final Duration progressWriteInterval;

  /// How many times an interrupted upload is resumed before giving up.
  final int maxResumeAttempts;

  /// Called whenever the engine starts/advances work (service notification).
  void Function(EngineActivity activity)? onActivity;

  static bool _defaultFileExists(String path) => File(path).existsSync();

  /// Processes every upload whose time has come. Returns how many were run.
  Future<int> processDue() async {
    final due = await _repository.getDue(now: _clock());
    var processed = 0;
    for (final upload in due) {
      if (upload.id == null) continue;
      if (await _process(upload)) processed++;
    }
    return processed;
  }

  /// Picks up uploads that were left "triggered"/"uploading" by a killed
  /// process. If the video is still on the device and the attempt budget is
  /// not spent, the upload is resumed right here (YouTube continues from the
  /// last confirmed byte via the stored session URI; platforms that already
  /// finished are not repeated). Otherwise it is marked as failed.
  ///
  /// [staleAfter] overrides [staleTimeout]; the service uses a short window at
  /// start-up because nothing can be in flight in a freshly started process.
  /// Returns how many uploads were resumed or failed.
  Future<int> recoverInterrupted({Duration? staleAfter}) async {
    final threshold = staleAfter ?? staleTimeout;
    final now = _clock();
    var recovered = 0;
    for (final stale in await _repository.getActive()) {
      final id = stale.id;
      if (id == null) continue;
      if (now.difference(stale.updatedAt) < threshold) continue;

      // Take ownership so a concurrently starting isolate does not resume
      // the same upload twice.
      final claimed = await _repository.claim(
        id,
        from: stale.status,
        to: UploadStatus.triggered,
      );
      if (!claimed) continue;
      final upload = await _repository.getById(id) ?? stale;

      if (!_fileExists(upload.videoPath)) {
        await _failInterrupted(
          upload,
          'Interrupted: the app or its background service was stopped during '
          'the upload and the video file is no longer on this device.',
        );
        recovered++;
        continue;
      }
      if (upload.retryCount >= maxResumeAttempts) {
        await _failInterrupted(
          upload,
          'Interrupted: the app or its background service was stopped during '
          'the upload $maxResumeAttempts times. Reschedule to try again.',
        );
        recovered++;
        continue;
      }

      await _repository.updateStatus(id, incrementRetryCount: true);
      final attempt = upload.retryCount + 1;
      await _repository.logEvent(
        id,
        'Upload was interrupted (no progress since '
        '${Formatters.time(upload.updatedAt)}). Resuming — attempt $attempt '
        'of $maxResumeAttempts.',
        level: EventLevel.warning,
      );
      _emit(id, upload.title, 'Resuming interrupted upload…');
      await _runUploads(
        (await _repository.getById(id) ?? upload).copyWith(
          retryCount: attempt,
        ),
      );
      recovered++;
    }
    return recovered;
  }

  Future<void> _failInterrupted(ScheduledUpload upload, String error) async {
    final id = upload.id!;
    await _repository.updateStatus(
      id,
      status: UploadStatus.failed,
      youtubeStatus: upload.youtubeStatus == PlatformUploadStatus.uploading
          ? PlatformUploadStatus.failed
          : null,
      instagramStatus: upload.instagramStatus == PlatformUploadStatus.uploading
          ? PlatformUploadStatus.failed
          : null,
      errorMessage: error,
      clearYoutubeUploadUri: true,
    );
    await _repository.logEvent(id, error, level: EventLevel.error);
    final refreshed = await _repository.getById(id) ?? upload;
    _emit(id, refreshed.title, 'Failed');
    await _notifier.uploadFailed(refreshed, error);
    await _notifyAgentFailure(refreshed, error);
  }

  // ---------------------------------------------------------------------------

  Future<bool> _process(ScheduledUpload due) async {
    final id = due.id!;
    final claimed = await _repository.claim(
      id,
      from: UploadStatus.scheduled,
      to: UploadStatus.triggered,
    );
    if (!claimed) return false; // someone else got it first

    final upload = await _repository.getById(id) ?? due;
    final now = _clock();
    final lateBy = now.difference(upload.scheduledTime);
    await _repository.logEvent(
      id,
      lateBy > const Duration(minutes: 1)
          ? 'Time reached (${Formatters.time(now)}, ${Formatters.countdown(upload.scheduledTime, now: now)}). Starting upload.'
          : 'Time reached (${Formatters.time(now)}). Starting upload.',
    );
    _emit(id, upload.title, 'Time reached — notifying…');

    await _notifier.uploadStarting(upload);
    await _notifyAgentStarting(upload);

    if (!_fileExists(upload.videoPath)) {
      const error =
          'The video file is no longer on this device (it was deleted or the '
          'storage was cleared).';
      await _finish(upload, errors: const [error]);
      return true;
    }

    await _repository.updateStatus(
      id,
      status: UploadStatus.uploading,
      uploadProgress: 0,
    );
    await _runUploads(upload.copyWith(status: UploadStatus.uploading));
    return true;
  }

  /// Uploads to every platform that is not finished yet, then records the
  /// final state. Shared by the normal path and by [recoverInterrupted].
  Future<void> _runUploads(ScheduledUpload initial) async {
    final id = initial.id!;
    var upload = initial;
    if (upload.status != UploadStatus.uploading) {
      await _repository.updateStatus(id, status: UploadStatus.uploading);
    }

    AppSettings settings;
    try {
      settings = await _settingsService.load();
    } catch (e) {
      await _repository.logEvent(
        id,
        'Could not read API keys from secure storage: $e',
        level: EventLevel.warning,
      );
      settings = const AppSettings();
    }

    final targets = <UploadPlatform>[
      if (upload.platform.includesYouTube) UploadPlatform.youtube,
      if (upload.platform.includesInstagram) UploadPlatform.instagram,
    ];
    final errors = <String>[];

    for (var index = 0; index < targets.length; index++) {
      final platform = targets[index];
      if (_platformStatus(upload, platform) == PlatformUploadStatus.completed) {
        // Already done before an interruption; do not upload twice.
        await _repository.logEvent(
          id,
          '${platform.label} upload had already finished; skipping.',
        );
        continue;
      }
      await _setPlatformStatus(id, platform, PlatformUploadStatus.uploading);
      _emit(id, upload.title, 'Uploading to ${platform.label}…', 0);

      final throttle = _ProgressThrottle(progressWriteInterval, _clock);
      final outcome = await _runUploader(
        platform,
        upload,
        settings,
        onProgress: (p) {
          final overall =
              (index + p.clamp(0.0, 1.0).toDouble()) / targets.length;
          _emit(id, upload.title, 'Uploading to ${platform.label}…', overall);
          if (!throttle.shouldWrite(overall)) return;
          // Best effort; progress rows are not worth failing an upload over.
          _repository
              .updateStatus(id, uploadProgress: overall)
              .catchError((_) {});
        },
      );

      if (outcome.succeeded) {
        await _setPlatformStatus(
          id,
          platform,
          PlatformUploadStatus.completed,
          remoteId: outcome.remoteId,
        );
        await _repository.logEvent(
          id,
          '${platform.label} upload finished'
          '${outcome.remoteId == null ? '' : ' (id ${outcome.remoteId})'}.',
        );
      } else {
        final error = outcome.error ?? '${platform.label} upload failed.';
        await _setPlatformStatus(id, platform, PlatformUploadStatus.failed);
        await _repository.logEvent(id, error, level: EventLevel.error);
        errors.add(error);
      }
    }

    upload = await _repository.getById(id) ?? upload;
    await _finish(upload, errors: errors);
  }

  static PlatformUploadStatus _platformStatus(
    ScheduledUpload upload,
    UploadPlatform platform,
  ) => switch (platform) {
    UploadPlatform.youtube => upload.youtubeStatus,
    UploadPlatform.instagram => upload.instagramStatus,
    UploadPlatform.both => throw ArgumentError('per-platform only'),
  };

  Future<UploadOutcome> _runUploader(
    UploadPlatform platform,
    ScheduledUpload upload,
    AppSettings settings, {
    required UploadProgressCallback onProgress,
  }) async {
    final uploader = _uploaders[platform];
    if (uploader == null) {
      return UploadOutcome.failure(
        'No uploader registered for ${platform.label}.',
      );
    }
    final id = upload.id!;
    try {
      return await uploader.upload(
        upload,
        settings: settings,
        onProgress: onProgress,
        log: (message) => _repository.logEvent(id, message),
        saveSession: (session) => switch (platform) {
          UploadPlatform.youtube => _repository.updateStatus(
            id,
            youtubeUploadUri: session,
            clearYoutubeUploadUri: session == null,
          ),
          // Instagram (Phase 5) restarts from scratch; nothing to persist.
          _ => Future<void>.value(),
        },
      );
    } catch (e) {
      return UploadOutcome.failure('${platform.label} upload crashed: $e');
    }
  }

  Future<void> _finish(
    ScheduledUpload upload, {
    required List<String> errors,
  }) async {
    final id = upload.id!;
    final succeeded = errors.isEmpty;
    final errorMessage = succeeded ? null : errors.join(' | ');

    await _repository.updateStatus(
      id,
      status: succeeded ? UploadStatus.completed : UploadStatus.failed,
      uploadProgress: succeeded ? 1 : null,
      errorMessage: errorMessage,
      clearErrorMessage: succeeded,
      // A session is only kept while a transfer may still be resumed; after a
      // terminal state a retry starts a fresh upload.
      clearYoutubeUploadUri: true,
    );
    final finalState = await _repository.getById(id) ?? upload;

    if (succeeded) {
      await _repository.logEvent(
        id,
        'All uploads completed. ${finalState.statusSummary}',
      );
      _emit(id, finalState.title, 'Completed', 1);
      await _notifier.uploadCompleted(finalState);
      await _notifyAgentCompleted(finalState);
    } else {
      await _repository.logEvent(
        id,
        'Marked as failed. ${finalState.statusSummary}',
        level: EventLevel.error,
      );
      _emit(id, finalState.title, 'Failed');
      await _notifier.uploadFailed(finalState, errorMessage!);
      await _notifyAgentFailure(finalState, errorMessage);
    }
  }

  Future<void> _setPlatformStatus(
    int id,
    UploadPlatform platform,
    PlatformUploadStatus status, {
    String? remoteId,
  }) {
    return switch (platform) {
      UploadPlatform.youtube => _repository.updateStatus(
        id,
        youtubeStatus: status,
        youtubeVideoId: remoteId,
      ),
      UploadPlatform.instagram => _repository.updateStatus(
        id,
        instagramStatus: status,
        instagramMediaId: remoteId,
      ),
      UploadPlatform.both => throw ArgumentError(
        'Platform status must be set per platform',
      ),
    };
  }

  // --- WhatsApp agent (best effort, always logged) ----------------------------

  Future<void> _notifyAgentStarting(ScheduledUpload upload) async {
    final id = upload.id!;
    if (!await _agent.isConfigured()) {
      await _repository.logEvent(
        id,
        'WhatsApp agent not configured — "Time reached" message skipped.',
        level: EventLevel.warning,
      );
      return;
    }
    try {
      await _agent.notifyUploadStarting(upload);
      await _repository.logEvent(
        id,
        'WhatsApp: sent "Time reached. Starting upload for ${upload.title}."',
      );
    } catch (e) {
      await _repository.logEvent(
        id,
        'WhatsApp "Time reached" message failed: $e',
        level: EventLevel.warning,
      );
    }
  }

  Future<void> _notifyAgentCompleted(ScheduledUpload upload) async {
    if (!await _agent.isConfigured()) return;
    try {
      await _agent.notifyUploadCompleted(upload);
      await _repository.logEvent(upload.id!, 'WhatsApp: completion message sent.');
    } catch (e) {
      await _repository.logEvent(
        upload.id!,
        'WhatsApp completion message failed: $e',
        level: EventLevel.warning,
      );
    }
  }

  Future<void> _notifyAgentFailure(ScheduledUpload upload, String error) async {
    if (!await _agent.isConfigured()) return;
    try {
      await _agent.notifyUploadFailed(upload, error);
      await _repository.logEvent(upload.id!, 'WhatsApp: error message sent.');
    } catch (e) {
      await _repository.logEvent(
        upload.id!,
        'WhatsApp error message failed: $e',
        level: EventLevel.warning,
      );
    }
  }

  void _emit(int id, String title, String message, [double? progress]) {
    onActivity?.call(
      EngineActivity(
        uploadId: id,
        title: title,
        message: message,
        progress: progress,
      ),
    );
  }
}

/// Limits how often progress is persisted (every callback would hammer
/// SQLite), while always letting 0 % and 100 % through.
class _ProgressThrottle {
  _ProgressThrottle(this._interval, this._clock);

  final Duration _interval;
  final DateTime Function() _clock;
  DateTime? _lastWrite;
  double _lastValue = -1;

  bool shouldWrite(double value) {
    final now = _clock();
    final last = _lastWrite;
    final due =
        last == null ||
        value >= 1 ||
        now.difference(last) >= _interval ||
        (value - _lastValue).abs() >= 0.05;
    if (!due) return false;
    _lastWrite = now;
    _lastValue = value;
    return true;
  }
}
