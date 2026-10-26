/// App-wide constants.
abstract final class AppConstants {
  static const String appName = 'Content Automation';

  // --- Storage ---------------------------------------------------------------
  static const String databaseName = 'content_automation.db';
  static const int databaseVersion = 1;

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

  // --- Scheduling ------------------------------------------------------------
  /// A schedule must be at least this far in the future when it is saved.
  static const Duration minimumScheduleLeadTime = Duration(minutes: 1);

  /// How often the home screen refreshes its countdown labels.
  static const Duration countdownRefreshInterval = Duration(seconds: 30);
}
