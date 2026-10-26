/// App-wide constants.
abstract final class AppConstants {
  static const String appName = 'Content Automation';

  // --- Storage ---------------------------------------------------------------
  static const String databaseName = 'content_automation.db';
  static const int databaseVersion = 2;

  /// Sub-folder (inside the app's private documents directory) where picked
  /// videos are kept until their scheduled upload time.
  static const String videoStorageFolder = 'scheduled_videos';

  // --- Platform limits (used for form validation) ----------------------------
  /// YouTube: title max 100 chars, description max 5000, tags max 500 total.
  static const int youtubeTitleMaxLength = 100;
  static const int youtubeDescriptionMaxLength = 5000;
  static const int youtubeTagsMaxTotalLength = 500;

  /// Instagram captions are limited to 2200 characters.
  static const int instagramCaptionMaxLength = 2200;

  // --- YouTube upload (Phase 4) -----------------------------------------------
  /// Resumable upload chunk size; must be a multiple of 256 KiB.
  static const int youtubeUploadChunkSize = 4 * 1024 * 1024;

  /// YouTube category used for every upload (22 = People & Blogs).
  static const String youtubeDefaultCategoryId = '22';

  /// How often an interrupted upload is resumed automatically before it is
  /// marked as failed.
  static const int maxUploadResumeAttempts = 3;

  /// At service start an in-flight upload without progress for this long is
  /// treated as interrupted (progress is written every few seconds while
  /// bytes flow). The watchdog uses the longer [staleUploadTimeout].
  static const Duration serviceStartStaleTimeout = Duration(minutes: 3);

  // --- Scheduling ------------------------------------------------------------
  /// A schedule must be at least this far in the future when it is saved.
  static const Duration minimumScheduleLeadTime = Duration(minutes: 1);

  /// How often the home screen refreshes its countdown labels.
  static const Duration countdownRefreshInterval = Duration(seconds: 30);

  // --- Background scheduler (Phase 2) -----------------------------------------
  /// With exact alarms available the foreground service is woken this long
  /// before the next due time, then counts down with a precise timer.
  static const Duration exactWakeupLead = Duration(minutes: 2);

  /// Without exact alarms the OS may deliver the wake-up late, so it is armed
  /// much earlier and the service simply waits.
  static const Duration inexactWakeupLead = Duration(minutes: 20);

  /// WorkManager one-off fallback is requested this long before the due time
  /// (WorkManager timing is approximate; this is a safety net, not the clock).
  static const Duration fallbackWakeupLead = Duration(minutes: 15);

  /// Periodic WorkManager watchdog (15 min is the platform minimum).
  static const Duration watchdogInterval = Duration(minutes: 15);

  /// While running, the service re-checks the queue at least this often.
  static const Duration serviceHeartbeat = Duration(seconds: 30);

  /// An upload that is "triggered"/"uploading" but has not been touched for
  /// this long is considered interrupted (process killed) and marked failed.
  static const Duration staleUploadTimeout = Duration(minutes: 20);

  // Notification plumbing.
  static const String schedulerChannelId = 'scheduler_status';
  static const String eventsChannelId = 'upload_events';
  static const int foregroundNotificationId = 1001;

  /// Event notifications use `eventNotificationBase + uploadId`.
  static const int eventNotificationBase = 5000;

  // WorkManager task identifiers.
  static const String watchdogTaskName = 'content_automation.watchdog';
  static const String wakeupTaskName = 'content_automation.wakeup';
}
