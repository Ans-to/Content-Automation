import '../../core/utils/formatters.dart';
import '../../data/models/enums.dart';
import '../../data/models/scheduled_upload.dart';
import '../../data/repositories/schedule_repository.dart';
import 'whatsapp_messages.dart';

/// Turns the local database into the reply for a "Status" message.
///
/// First line is always `YouTube: [Status] | Instagram: [Status]` for the
/// most relevant upload (in progress > next scheduled > most recent), followed
/// by a short context line and, when there are more uploads, a compact list.
class StatusReplyBuilder {
  StatusReplyBuilder(this._repository, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final ScheduleRepository _repository;
  final DateTime Function() _clock;

  static const int maxOthers = 4;

  Future<String> build({String? filter}) async {
    final now = _clock();
    var uploads = await _repository.getAll();

    if (uploads.isEmpty) {
      return 'No uploads scheduled.';
    }

    final query = filter?.trim().toLowerCase();
    if (query != null && query.isNotEmpty) {
      final matches = uploads
          .where((u) => u.title.toLowerCase().contains(query))
          .toList();
      if (matches.isEmpty) {
        return 'No upload matching "${filter!.trim()}". '
            'Reply "Status" for all uploads.';
      }
      uploads = matches;
    }

    final ordered = _ordered(uploads, now);
    final primary = ordered.first;
    final buffer = StringBuffer()
      ..writeln(WhatsAppMessages.platformLine(primary))
      ..write(_context(primary, now));

    final others = ordered.skip(1).toList();
    if (others.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln()
        ..write('Other uploads:');
      for (final upload in others.take(maxOthers)) {
        buffer
          ..writeln()
          ..write('• ${upload.title} — ${WhatsAppMessages.platformLine(upload)}'
              ' (${_shortState(upload, now)})');
      }
      if (others.length > maxOthers) {
        buffer
          ..writeln()
          ..write('…and ${others.length - maxOthers} more.');
      }
    }
    return buffer.toString();
  }

  /// In-flight first (earliest scheduled), then upcoming (soonest), then
  /// finished (most recently updated).
  static List<ScheduledUpload> _ordered(
    List<ScheduledUpload> uploads,
    DateTime now,
  ) {
    int rank(ScheduledUpload u) => switch (u.status) {
      UploadStatus.triggered || UploadStatus.uploading => 0,
      UploadStatus.scheduled => 1,
      UploadStatus.failed || UploadStatus.completed => 2,
    };
    final sorted = [...uploads]
      ..sort((a, b) {
        final byRank = rank(a).compareTo(rank(b));
        if (byRank != 0) return byRank;
        return rank(a) == 2
            ? b.updatedAt.compareTo(a.updatedAt)
            : a.scheduledTime.compareTo(b.scheduledTime);
      });
    return sorted;
  }

  static String _context(ScheduledUpload upload, DateTime now) {
    final when = Formatters.dateTime(upload.scheduledTime);
    return switch (upload.status) {
      UploadStatus.scheduled =>
        '"${upload.title}" — scheduled for $when '
            '(${Formatters.countdown(upload.scheduledTime, now: now)}).',
      UploadStatus.triggered =>
        '"${upload.title}" — time reached, starting the upload.',
      UploadStatus.uploading =>
        '"${upload.title}" — uploading, '
            '${Formatters.percent(upload.uploadProgress)} overall.',
      UploadStatus.completed =>
        '"${upload.title}" — completed '
            '${Formatters.dateTime(upload.updatedAt)}.',
      UploadStatus.failed =>
        '"${upload.title}" — failed'
            '${upload.errorMessage == null ? '' : ': ${upload.errorMessage}'}',
    };
  }

  static String _shortState(ScheduledUpload upload, DateTime now) =>
      switch (upload.status) {
        UploadStatus.scheduled =>
          'scheduled, ${Formatters.countdown(upload.scheduledTime, now: now)}',
        UploadStatus.triggered => 'starting',
        UploadStatus.uploading =>
          'uploading ${Formatters.percent(upload.uploadProgress)}',
        UploadStatus.completed => 'completed',
        UploadStatus.failed => 'failed',
      };
}
