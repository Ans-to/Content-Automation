/// Which destination(s) an upload targets.
enum UploadPlatform {
  youtube('youtube', 'YouTube'),
  instagram('instagram', 'Instagram'),
  both('both', 'YouTube + Instagram');

  const UploadPlatform(this.dbValue, this.label);

  /// Value persisted in SQLite.
  final String dbValue;

  /// Human readable label.
  final String label;

  bool get includesYouTube =>
      this == UploadPlatform.youtube || this == UploadPlatform.both;

  bool get includesInstagram =>
      this == UploadPlatform.instagram || this == UploadPlatform.both;

  static UploadPlatform fromDb(String? value) => UploadPlatform.values
      .firstWhere((e) => e.dbValue == value, orElse: () => UploadPlatform.both);

  /// Builds the platform from two toggles. Throws if neither is selected.
  static UploadPlatform fromSelection({
    required bool youtube,
    required bool instagram,
  }) {
    if (youtube && instagram) return UploadPlatform.both;
    if (youtube) return UploadPlatform.youtube;
    if (instagram) return UploadPlatform.instagram;
    throw ArgumentError('At least one platform must be selected.');
  }
}

/// Overall lifecycle state of a scheduled upload.
enum UploadStatus {
  /// Waiting on the device for the scheduled time.
  scheduled('scheduled', 'Scheduled'),

  /// Scheduled time reached; WhatsApp notification being sent.
  triggered('triggered', 'Time reached'),

  /// At least one platform upload is in progress.
  uploading('uploading', 'Uploading'),

  /// Every selected platform finished successfully.
  completed('completed', 'Completed'),

  /// At least one selected platform failed.
  failed('failed', 'Failed');

  const UploadStatus(this.dbValue, this.label);

  final String dbValue;
  final String label;

  bool get isTerminal =>
      this == UploadStatus.completed || this == UploadStatus.failed;

  bool get isActive =>
      this == UploadStatus.triggered || this == UploadStatus.uploading;

  /// Whether the user may still edit metadata / schedule.
  bool get isEditable =>
      this == UploadStatus.scheduled || this == UploadStatus.failed;

  static UploadStatus fromDb(String? value) => UploadStatus.values.firstWhere(
    (e) => e.dbValue == value,
    orElse: () => UploadStatus.scheduled,
  );
}

/// Per-platform state (reported back over WhatsApp as
/// "YouTube: [Status] | Instagram: [Status]").
enum PlatformUploadStatus {
  notApplicable('n/a', 'N/A'),
  pending('pending', 'Pending'),
  uploading('uploading', 'Uploading'),
  processing('processing', 'Processing'),
  completed('completed', 'Completed'),
  failed('failed', 'Failed');

  const PlatformUploadStatus(this.dbValue, this.label);

  final String dbValue;
  final String label;

  bool get isFinished =>
      this == PlatformUploadStatus.completed ||
      this == PlatformUploadStatus.failed ||
      this == PlatformUploadStatus.notApplicable;

  static PlatformUploadStatus fromDb(String? value) =>
      PlatformUploadStatus.values.firstWhere(
        (e) => e.dbValue == value,
        orElse: () => PlatformUploadStatus.pending,
      );
}

/// Severity of an entry in the per-upload activity log.
enum EventLevel {
  info('info'),
  warning('warning'),
  error('error');

  const EventLevel(this.dbValue);

  final String dbValue;

  static EventLevel fromDb(String? value) => EventLevel.values.firstWhere(
    (e) => e.dbValue == value,
    orElse: () => EventLevel.info,
  );
}
