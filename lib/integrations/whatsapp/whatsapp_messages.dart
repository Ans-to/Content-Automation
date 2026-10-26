import '../../core/utils/formatters.dart';
import '../../data/models/enums.dart';
import '../../data/models/scheduled_upload.dart';

/// The exact texts exchanged with the WhatsApp agent.
abstract final class WhatsAppMessages {
  /// Sent the moment a scheduled time is reached.
  static String timeReached(ScheduledUpload upload) =>
      'Time reached. Starting upload for ${upload.title}.';

  static String uploadFailed(ScheduledUpload upload, String error) =>
      'Upload failed for ${upload.title}.\n'
      '${upload.statusSummary}\n'
      'Reason: $error';

  static String uploadCompleted(ScheduledUpload upload) {
    final buffer = StringBuffer()
      ..writeln('Upload completed for ${upload.title}.')
      ..write(upload.statusSummary);
    final youtubeId = upload.youtubeVideoId;
    if (youtubeId != null && youtubeId.isNotEmpty) {
      buffer.write('\nYouTube: https://youtu.be/$youtubeId');
    }
    final instagramId = upload.instagramMediaId;
    if (instagramId != null && instagramId.isNotEmpty) {
      buffer.write('\nInstagram media id: $instagramId');
    }
    return buffer.toString();
  }

  /// Sent from the Settings screen to verify the agent configuration.
  static String test(DateTime now) =>
      'Content Automation test message (${Formatters.dateTime(now)}). '
      'If you can read this, alerts are set up correctly. '
      'Reply "Status" to get the upload status.';

  // --- Inbound ---------------------------------------------------------------

  static final RegExp _statusPattern = RegExp(
    r'^\s*[\W_]*status\b[\s:,-]*(.*?)[\s.!?]*$',
    caseSensitive: false,
    dotAll: true,
  );

  /// `true` for "Status", "status?", "STATUS launch teaser", "/status" …
  static bool isStatusRequest(String text) =>
      _statusPattern.hasMatch(text.trim());

  /// The optional title filter after the keyword ("status launch" → "launch").
  static String? statusFilter(String text) {
    final match = _statusPattern.firstMatch(text.trim());
    final filter = match?.group(1)?.trim();
    return (filter == null || filter.isEmpty) ? null : filter;
  }

  /// One upload as "YouTube: X | Instagram: Y" with live progress.
  static String platformLine(ScheduledUpload upload) {
    String label(PlatformUploadStatus status) {
      if (status == PlatformUploadStatus.uploading &&
          upload.status == UploadStatus.uploading) {
        return '${status.label} (${Formatters.percent(upload.uploadProgress)})';
      }
      return status.label;
    }

    return 'YouTube: ${label(upload.youtubeStatus)} | '
        'Instagram: ${label(upload.instagramStatus)}';
  }
}
