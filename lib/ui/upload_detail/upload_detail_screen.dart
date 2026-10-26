import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/utils/formatters.dart';
import '../../data/models/enums.dart';
import '../../data/models/scheduled_upload.dart';
import '../../data/models/upload_event.dart';
import '../../state/schedule_provider.dart';
import '../add_upload/add_upload_screen.dart';
import '../widgets/platform_badge.dart';
import '../widgets/status_chip.dart';

/// Everything about one scheduled upload, including its activity log.
class UploadDetailScreen extends StatefulWidget {
  const UploadDetailScreen({super.key, required this.uploadId});

  final int uploadId;

  @override
  State<UploadDetailScreen> createState() => _UploadDetailScreenState();
}

class _UploadDetailScreenState extends State<UploadDetailScreen> {
  late Future<List<UploadEvent>> _events;
  late Future<bool> _videoExists;

  @override
  void initState() {
    super.initState();
    _refreshAsync();
  }

  void _refreshAsync() {
    final provider = context.read<ScheduleProvider>();
    final upload = provider.byId(widget.uploadId);
    _events = provider.eventsFor(widget.uploadId);
    _videoExists = upload == null
        ? Future.value(false)
        : provider.videoExists(upload);
  }

  Future<void> _edit(ScheduledUpload upload) async {
    final result = await Navigator.of(context).push<ScheduledUpload>(
      MaterialPageRoute(builder: (_) => AddUploadScreen(existing: upload)),
    );
    if (result != null && mounted) {
      setState(_refreshAsync);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Changes saved')));
    }
  }

  Future<void> _reschedule(ScheduledUpload upload) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final initial = now.add(const Duration(minutes: 10));
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: today,
      lastDate: today.add(const Duration(days: 365 * 2)),
      helpText: 'New upload date',
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
      helpText: 'New upload time',
    );
    if (time == null || !mounted) return;

    final newTime = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    final messenger = ScaffoldMessenger.of(context);
    if (!newTime.isAfter(DateTime.now())) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Please pick a time in the future.')),
      );
      return;
    }
    await context.read<ScheduleProvider>().reschedule(upload, newTime);
    if (!mounted) return;
    setState(_refreshAsync);
    messenger.showSnackBar(
      SnackBar(content: Text('Rescheduled for ${Formatters.dateTime(newTime)}')),
    );
  }

  Future<void> _delete(ScheduledUpload upload) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete scheduled upload?'),
        content: const Text(
          'This removes the schedule and the private video copy. '
          'Your original file is not affected.',
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
    if (confirmed != true || !mounted) return;
    final navigator = Navigator.of(context);
    await context.read<ScheduleProvider>().delete(upload);
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final upload = context.watch<ScheduleProvider>().byId(widget.uploadId);
    if (upload == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('This upload no longer exists.')),
      );
    }

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Upload details'),
        actions: [
          if (upload.status.isEditable)
            IconButton(
              tooltip: 'Edit',
              onPressed: () => _edit(upload),
              icon: const Icon(Icons.edit_outlined),
            ),
          if (!upload.status.isActive)
            IconButton(
              tooltip: 'Delete',
              onPressed: () => _delete(upload),
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          // --- Header ---------------------------------------------------------
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  upload.title,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    UploadStatusChip(status: upload.status),
                    PlatformBadges(platform: upload.platform),
                  ],
                ),
              ],
            ),
          ),

          if (upload.status == UploadStatus.uploading)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: upload.uploadProgress > 0
                          ? upload.uploadProgress
                          : null,
                      minHeight: 8,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Overall progress ${Formatters.percent(upload.uploadProgress)}',
                    style: theme.textTheme.labelMedium,
                  ),
                ],
              ),
            ),

          if (upload.status == UploadStatus.failed &&
              (upload.errorMessage?.isNotEmpty ?? false))
            Card(
              color: scheme.errorContainer,
              child: ListTile(
                leading: Icon(Icons.error_outline, color: scheme.onErrorContainer),
                title: Text(
                  'Last error',
                  style: TextStyle(
                    color: scheme.onErrorContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                subtitle: SelectableText(
                  upload.errorMessage!,
                  style: TextStyle(color: scheme.onErrorContainer),
                ),
              ),
            ),

          if (upload.status.isTerminal)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: FilledButton.tonalIcon(
                onPressed: () => _reschedule(upload),
                icon: const Icon(Icons.replay),
                label: Text(
                  upload.status == UploadStatus.failed
                      ? 'Retry at a new time'
                      : 'Upload again at a new time',
                ),
              ),
            ),

          // --- Schedule -------------------------------------------------------
          _Section(
            title: 'Schedule',
            children: [
              _InfoTile(
                icon: Icons.calendar_today_outlined,
                label: 'Scheduled for',
                value: Formatters.dateTime(upload.scheduledTime),
                trailing: upload.status == UploadStatus.scheduled
                    ? Formatters.countdown(upload.scheduledTime)
                    : null,
              ),
              _InfoTile(
                icon: Icons.history,
                label: 'Created',
                value: Formatters.dateTime(upload.createdAt),
              ),
              if (upload.retryCount > 0)
                _InfoTile(
                  icon: Icons.replay,
                  label: 'Retries',
                  value: '${upload.retryCount}',
                ),
            ],
          ),

          // --- Platforms ------------------------------------------------------
          _Section(
            title: 'Platforms',
            children: [
              if (upload.platform.includesYouTube)
                _PlatformRow(
                  badge: const PlatformBadge.youtube(),
                  status: upload.youtubeStatus,
                  remoteId: upload.youtubeVideoId,
                  remoteLabel: 'Video ID',
                ),
              if (upload.platform.includesInstagram)
                _PlatformRow(
                  badge: const PlatformBadge.instagram(),
                  status: upload.instagramStatus,
                  remoteId: upload.instagramMediaId,
                  remoteLabel: 'Media ID',
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Text(
                  'WhatsApp "Status" reply: ${upload.statusSummary}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),

          // --- Video ----------------------------------------------------------
          _Section(
            title: 'Video',
            children: [
              _InfoTile(
                icon: Icons.movie_outlined,
                label: 'File',
                value: upload.videoName,
                trailing: upload.videoSizeBytes > 0
                    ? Formatters.bytes(upload.videoSizeBytes)
                    : null,
              ),
              FutureBuilder<bool>(
                future: _videoExists,
                builder: (context, snapshot) {
                  final exists = snapshot.data;
                  return _InfoTile(
                    icon: exists == false
                        ? Icons.cloud_off_outlined
                        : Icons.storage_outlined,
                    label: 'Stored on device',
                    value: switch (exists) {
                      null => 'Checking…',
                      true => 'Yes · ready to upload at the scheduled time',
                      false => 'MISSING – the file is no longer on the device',
                    },
                    valueColor: exists == false ? scheme.error : null,
                    onLongPress: () => _copy(context, upload.videoPath),
                  );
                },
              ),
            ],
          ),

          // --- Metadata -------------------------------------------------------
          _Section(
            title: 'Metadata',
            children: [
              _InfoTile(
                icon: Icons.notes_outlined,
                label: 'Description',
                value: upload.description.isEmpty ? '—' : upload.description,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.sell_outlined, size: 20, color: scheme.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Tags', style: theme.textTheme.labelMedium),
                          const SizedBox(height: 4),
                          if (upload.tags.isEmpty)
                            const Text('—')
                          else
                            Wrap(
                              spacing: 6,
                              runSpacing: 0,
                              children: [
                                for (final tag in upload.tags)
                                  Chip(
                                    label: Text(tag),
                                    visualDensity: VisualDensity.compact,
                                    materialTapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          // --- Activity log ---------------------------------------------------
          _Section(
            title: 'Activity',
            children: [
              FutureBuilder<List<UploadEvent>>(
                future: _events,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final events = snapshot.data ?? const <UploadEvent>[];
                  if (events.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('No activity yet.'),
                    );
                  }
                  return Column(
                    children: [
                      for (final event in events) _EventTile(event: event),
                    ],
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _copy(BuildContext context, String text) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: text));
    messenger.showSnackBar(const SnackBar(content: Text('Path copied')));
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
          child: Text(
            title.toUpperCase(),
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
        ),
        Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ],
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({
    required this.icon,
    required this.label,
    required this.value,
    this.trailing,
    this.valueColor,
    this.onLongPress,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? trailing;
  final Color? valueColor;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(icon, color: theme.colorScheme.primary),
      title: Text(label, style: theme.textTheme.labelMedium),
      subtitle: Text(
        value,
        style: theme.textTheme.bodyMedium?.copyWith(color: valueColor),
      ),
      trailing: trailing == null
          ? null
          : Text(trailing!, style: theme.textTheme.labelMedium),
      onLongPress: onLongPress,
      dense: true,
    );
  }
}

class _PlatformRow extends StatelessWidget {
  const _PlatformRow({
    required this.badge,
    required this.status,
    required this.remoteId,
    required this.remoteLabel,
  });

  final Widget badge;
  final PlatformUploadStatus status;
  final String? remoteId;
  final String remoteLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          badge,
          const SizedBox(width: 12),
          Expanded(
            child: remoteId == null
                ? const SizedBox.shrink()
                : Text(
                    '$remoteLabel: $remoteId',
                    style: theme.textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
          ),
          PlatformStatusChip(status: status),
        ],
      ),
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event});

  final UploadEvent event;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (event.level) {
      EventLevel.info => (Icons.info_outline, scheme.primary),
      EventLevel.warning => (Icons.warning_amber_rounded, scheme.tertiary),
      EventLevel.error => (Icons.error_outline, scheme.error),
    };
    return ListTile(
      dense: true,
      leading: Icon(icon, color: color, size: 20),
      title: Text(event.message),
      subtitle: Text(Formatters.dateTime(event.timestamp)),
    );
  }
}
