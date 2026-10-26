import 'package:flutter/material.dart';

import '../../../core/utils/formatters.dart';
import '../../../data/models/enums.dart';
import '../../../data/models/scheduled_upload.dart';
import '../../widgets/platform_badge.dart';
import '../../widgets/status_chip.dart';

/// One row in the schedule list.
class UploadCard extends StatelessWidget {
  const UploadCard({
    super.key,
    required this.upload,
    required this.now,
    required this.onTap,
    required this.onDelete,
  });

  final ScheduledUpload upload;

  /// Injected so every card in a list shares one clock tick.
  final DateTime now;

  final VoidCallback onTap;

  /// Invoked after the user confirms a swipe-to-delete.
  final Future<void> Function() onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = StatusStyle.forUpload(upload.status, scheme);

    return Dismissible(
      key: ValueKey('upload-${upload.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        padding: const EdgeInsets.only(right: 24),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Icon(Icons.delete_outline, color: scheme.onErrorContainer),
      ),
      confirmDismiss: (_) => _confirmDelete(context),
      onDismissed: (_) => onDelete(),
      child: Card(
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Thumbnail(style: style),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        upload.title.isEmpty ? upload.videoName : upload.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      _ScheduleLine(upload: upload, now: now),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: PlatformBadges(
                              platform: upload.platform,
                              compact: true,
                            ),
                          ),
                          const SizedBox(width: 8),
                          UploadStatusChip(status: upload.status),
                        ],
                      ),
                      if (upload.status == UploadStatus.uploading) ...[
                        const SizedBox(height: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(999),
                          child: LinearProgressIndicator(
                            value: upload.uploadProgress > 0
                                ? upload.uploadProgress
                                : null,
                            minHeight: 6,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${Formatters.percent(upload.uploadProgress)} · '
                          '${upload.statusSummary}',
                          style: theme.textTheme.labelSmall,
                        ),
                      ],
                      if (upload.status == UploadStatus.failed &&
                          (upload.errorMessage?.isNotEmpty ?? false)) ...[
                        const SizedBox(height: 8),
                        Text(
                          upload.errorMessage!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.error,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<bool> _confirmDelete(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete scheduled upload?'),
        content: Text(
          '"${upload.title}" will be removed from the schedule and its '
          'private video copy deleted from the app storage. Your original '
          'video file is not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.style});

  final StatusStyle style;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        color: style.background,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Icon(Icons.movie_outlined, color: style.foreground, size: 26),
    );
  }
}

class _ScheduleLine extends StatelessWidget {
  const _ScheduleLine({required this.upload, required this.now});

  final ScheduledUpload upload;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final overdue = upload.status == UploadStatus.scheduled &&
        upload.scheduledTime.isBefore(now);

    final trailing = switch (upload.status) {
      UploadStatus.scheduled => Formatters.countdown(
        upload.scheduledTime,
        now: now,
      ),
      UploadStatus.triggered ||
      UploadStatus.uploading => 'started ${Formatters.time(upload.scheduledTime)}',
      UploadStatus.completed =>
        'finished ${Formatters.dateTime(upload.updatedAt)}',
      UploadStatus.failed => 'failed ${Formatters.dateTime(upload.updatedAt)}',
    };

    return Row(
      children: [
        Icon(
          Icons.calendar_today_outlined,
          size: 14,
          color: scheme.onSurfaceVariant,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            '${Formatters.dateTime(upload.scheduledTime)} · $trailing',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: overdue ? scheme.error : scheme.onSurfaceVariant,
              fontWeight: overdue ? FontWeight.w600 : null,
            ),
          ),
        ),
      ],
    );
  }
}
