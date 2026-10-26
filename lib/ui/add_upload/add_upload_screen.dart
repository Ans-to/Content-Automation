import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants.dart';
import '../../core/utils/formatters.dart';
import '../../data/models/enums.dart';
import '../../data/models/scheduled_upload.dart';
import '../../services/video_file_service.dart';
import '../../state/schedule_provider.dart';

/// Create (or edit, when [existing] is given) a scheduled upload.
class AddUploadScreen extends StatefulWidget {
  const AddUploadScreen({super.key, this.existing});

  final ScheduledUpload? existing;

  bool get isEditing => existing != null;

  @override
  State<AddUploadScreen> createState() => _AddUploadScreenState();
}

class _AddUploadScreenState extends State<AddUploadScreen> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _titleController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _tagsController;

  PlatformFile? _pickedFile;
  late DateTime _scheduledAt;
  late Set<UploadPlatform> _targets;
  List<String> _tagPreview = const [];

  bool _isSaving = false;
  double _copyProgress = 0;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _titleController = TextEditingController(text: existing?.title ?? '');
    _descriptionController = TextEditingController(
      text: existing?.description ?? '',
    );
    _tagsController = TextEditingController(text: existing?.tagsAsString ?? '');
    _tagPreview = existing?.tags ?? const [];
    _tagsController.addListener(_updateTagPreview);

    _scheduledAt = existing?.scheduledTime ?? _defaultScheduleTime();
    final platform = existing?.platform ?? UploadPlatform.both;
    _targets = {
      if (platform.includesYouTube) UploadPlatform.youtube,
      if (platform.includesInstagram) UploadPlatform.instagram,
    };
  }

  @override
  void dispose() {
    _tagsController.removeListener(_updateTagPreview);
    _titleController.dispose();
    _descriptionController.dispose();
    _tagsController.dispose();
    super.dispose();
  }

  /// One hour from now, rounded up to the next 5 minutes.
  static DateTime _defaultScheduleTime() {
    final base = DateTime.now().add(const Duration(hours: 1));
    final remainder = base.minute % 5;
    final rounded = remainder == 0 ? base : base.add(Duration(minutes: 5 - remainder));
    return DateTime(
      rounded.year,
      rounded.month,
      rounded.day,
      rounded.hour,
      rounded.minute,
    );
  }

  void _updateTagPreview() {
    final parsed = ScheduledUpload.parseTags(_tagsController.text);
    setState(() => _tagPreview = parsed);
  }

  UploadPlatform get _platform => UploadPlatform.fromSelection(
    youtube: _targets.contains(UploadPlatform.youtube),
    instagram: _targets.contains(UploadPlatform.instagram),
  );

  bool get _hasVideo => _pickedFile != null || widget.isEditing;

  // --- Actions ---------------------------------------------------------------

  Future<void> _pickVideo() async {
    final service = context.read<VideoFileService>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final file = await service.pickVideo();
      if (file == null || !mounted) return;
      setState(() => _pickedFile = file);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not open the video picker: $e')),
      );
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: _scheduledAt.isBefore(today) ? today : _scheduledAt,
      firstDate: today,
      lastDate: today.add(const Duration(days: 365 * 2)),
      helpText: 'Upload date',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _scheduledAt = DateTime(
        picked.year,
        picked.month,
        picked.day,
        _scheduledAt.hour,
        _scheduledAt.minute,
      );
    });
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_scheduledAt),
      helpText: 'Upload time',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _scheduledAt = DateTime(
        _scheduledAt.year,
        _scheduledAt.month,
        _scheduledAt.day,
        picked.hour,
        picked.minute,
      );
    });
  }

  String? _scheduleError() {
    final earliest = DateTime.now().add(AppConstants.minimumScheduleLeadTime);
    if (_scheduledAt.isBefore(earliest)) {
      return 'The scheduled time must be at least '
          '${AppConstants.minimumScheduleLeadTime.inMinutes} minute(s) from now.';
    }
    return null;
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    final messenger = ScaffoldMessenger.of(context);

    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (!_hasVideo) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Please select a video first.')),
      );
      return;
    }
    final scheduleError = _scheduleError();
    if (scheduleError != null) {
      messenger.showSnackBar(SnackBar(content: Text(scheduleError)));
      return;
    }

    setState(() {
      _isSaving = true;
      _copyProgress = 0;
    });

    final provider = context.read<ScheduleProvider>();
    final navigator = Navigator.of(context);
    try {
      final ScheduledUpload result;
      final existing = widget.existing;
      if (existing == null) {
        result = await provider.schedule(
          video: _pickedFile!,
          title: _titleController.text,
          description: _descriptionController.text,
          tags: _tagPreview,
          scheduledTime: _scheduledAt,
          platform: _platform,
          onCopyProgress: _onCopyProgress,
        );
      } else {
        result = await provider.edit(
          existing,
          title: _titleController.text,
          description: _descriptionController.text,
          tags: _tagPreview,
          scheduledTime: _scheduledAt,
          platform: _platform,
          newVideo: _pickedFile,
          onCopyProgress: _onCopyProgress,
        );
      }
      if (!mounted) return;
      navigator.pop(result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Could not save'),
          content: Text('$e'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  void _onCopyProgress(double progress) {
    if (!mounted) return;
    setState(() => _copyProgress = progress);
  }

  // --- UI --------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final instagramSelected = _targets.contains(UploadPlatform.instagram);

    return PopScope(
      canPop: !_isSaving,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.isEditing ? 'Edit upload' : 'Schedule upload'),
          actions: [
            TextButton.icon(
              onPressed: _isSaving ? null : _save,
              icon: const Icon(Icons.check),
              label: const Text('Save'),
            ),
          ],
        ),
        body: Stack(
          children: [
            Form(
              key: _formKey,
              autovalidateMode: AutovalidateMode.onUserInteraction,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                children: [
                  const _SectionTitle(
                    icon: Icons.movie_outlined,
                    title: 'Video',
                  ),
                  _VideoTile(
                    pickedFile: _pickedFile,
                    existing: widget.existing,
                    onPick: _isSaving ? null : _pickVideo,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'The video is copied into this app\'s private storage and '
                    'stays on the phone until the exact scheduled time. '
                    'Nothing is uploaded now.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 20),
                  const _SectionTitle(icon: Icons.public, title: 'Platforms'),
                  SegmentedButton<UploadPlatform>(
                    segments: const [
                      ButtonSegment(
                        value: UploadPlatform.youtube,
                        label: Text('YouTube'),
                        icon: Icon(Icons.play_circle_outline),
                      ),
                      ButtonSegment(
                        value: UploadPlatform.instagram,
                        label: Text('Instagram'),
                        icon: Icon(Icons.camera_alt_outlined),
                      ),
                    ],
                    selected: _targets,
                    multiSelectionEnabled: true,
                    emptySelectionAllowed: false,
                    onSelectionChanged: _isSaving
                        ? null
                        : (selection) => setState(() => _targets = selection),
                  ),
                  const SizedBox(height: 20),
                  const _SectionTitle(icon: Icons.notes_outlined, title: 'Details'),
                  TextFormField(
                    controller: _titleController,
                    enabled: !_isSaving,
                    maxLength: AppConstants.youtubeTitleMaxLength,
                    textInputAction: TextInputAction.next,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'Title',
                      hintText: 'e.g. 5 tips for better morning routines',
                      prefixIcon: Icon(Icons.title),
                    ),
                    validator: (value) {
                      final text = value?.trim() ?? '';
                      if (text.isEmpty) return 'A title is required.';
                      if (text.length > AppConstants.youtubeTitleMaxLength) {
                        return 'Max ${AppConstants.youtubeTitleMaxLength} characters.';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _descriptionController,
                    enabled: !_isSaving,
                    maxLength: AppConstants.youtubeDescriptionMaxLength,
                    maxLines: 6,
                    minLines: 3,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      labelText: 'Description',
                      helperText: instagramSelected
                          ? 'Also used as the Instagram caption (max '
                                '${AppConstants.instagramCaptionMaxLength} characters).'
                          : null,
                      helperMaxLines: 2,
                      alignLabelWithHint: true,
                      prefixIcon: const Padding(
                        padding: EdgeInsets.only(bottom: 72),
                        child: Icon(Icons.notes_outlined),
                      ),
                    ),
                    validator: (value) {
                      final text = value?.trim() ?? '';
                      if (text.length > AppConstants.youtubeDescriptionMaxLength) {
                        return 'Max ${AppConstants.youtubeDescriptionMaxLength} characters.';
                      }
                      if (instagramSelected &&
                          text.length > AppConstants.instagramCaptionMaxLength) {
                        return 'Instagram captions are limited to '
                            '${AppConstants.instagramCaptionMaxLength} characters.';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _tagsController,
                    enabled: !_isSaving,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(
                      labelText: 'Tags',
                      hintText: 'productivity, morning routine, habits',
                      helperText: 'Comma-separated. Used as YouTube tags.',
                      prefixIcon: Icon(Icons.sell_outlined),
                    ),
                    validator: (_) {
                      final total = _tagPreview.join(',').length;
                      if (total > AppConstants.youtubeTagsMaxTotalLength) {
                        return 'YouTube allows at most '
                            '${AppConstants.youtubeTagsMaxTotalLength} characters of '
                            'tags in total (currently $total).';
                      }
                      return null;
                    },
                  ),
                  if (_tagPreview.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 0,
                      children: [
                        for (final tag in _tagPreview)
                          Chip(
                            label: Text(tag),
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 20),
                  const _SectionTitle(icon: Icons.schedule, title: 'Schedule'),
                  Card(
                    margin: EdgeInsets.zero,
                    child: Column(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.calendar_today_outlined),
                          title: const Text('Date'),
                          subtitle: Text(Formatters.date(_scheduledAt)),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: _isSaving ? null : _pickDate,
                        ),
                        const Divider(height: 1),
                        ListTile(
                          leading: const Icon(Icons.access_time),
                          title: const Text('Time'),
                          subtitle: Text(Formatters.time(_scheduledAt)),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: _isSaving ? null : _pickTime,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Builder(
                    builder: (context) {
                      final error = _scheduleError();
                      final scheme = Theme.of(context).colorScheme;
                      return Row(
                        children: [
                          Icon(
                            error == null
                                ? Icons.event_available_outlined
                                : Icons.warning_amber_rounded,
                            size: 16,
                            color: error == null
                                ? scheme.onSurfaceVariant
                                : scheme.error,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              error ??
                                  'Goes live ${Formatters.countdown(_scheduledAt)} '
                                      '(${Formatters.dateTime(_scheduledAt)}).',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: error == null
                                    ? scheme.onSurfaceVariant
                                    : scheme.error,
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 28),
                  FilledButton.icon(
                    onPressed: _isSaving ? null : _save,
                    icon: Icon(
                      widget.isEditing ? Icons.save_outlined : Icons.schedule_send,
                    ),
                    label: Text(
                      widget.isEditing ? 'Save changes' : 'Schedule upload',
                    ),
                  ),
                ],
              ),
            ),
            if (_isSaving)
              _SavingOverlay(
                progress: _copyProgress,
                label: _pickedFile == null
                    ? 'Saving…'
                    : 'Copying video into app storage…',
              ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _VideoTile extends StatelessWidget {
  const _VideoTile({
    required this.pickedFile,
    required this.existing,
    required this.onPick,
  });

  final PlatformFile? pickedFile;
  final ScheduledUpload? existing;
  final VoidCallback? onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final String? name;
    final int? size;
    final String? caption;
    if (pickedFile != null) {
      name = pickedFile!.name;
      size = pickedFile!.lengthSync();
      caption = existing != null ? 'New video (replaces the current one)' : null;
    } else if (existing != null) {
      name = existing!.videoName;
      size = existing!.videoSizeBytes;
      caption = 'Current video';
    } else {
      name = null;
      size = null;
      caption = null;
    }

    if (name == null) {
      return OutlinedButton.icon(
        onPressed: onPick,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 28),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        icon: const Icon(Icons.video_file_outlined, size: 28),
        label: const Text('Select a video from this phone'),
      );
    }

    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(Icons.movie_outlined, color: scheme.onPrimaryContainer),
        ),
        title: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          [
            if (size != null && size > 0) Formatters.bytes(size),
            ?caption,
          ].join(' · '),
        ),
        trailing: TextButton(
          onPressed: onPick,
          child: Text(existing != null ? 'Replace' : 'Change'),
        ),
      ),
    );
  }
}

class _SavingOverlay extends StatelessWidget {
  const _SavingOverlay({required this.progress, required this.label});

  final double progress;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Positioned.fill(
      child: AbsorbPointer(
        child: ColoredBox(
          color: theme.colorScheme.scrim.withValues(alpha: 0.35),
          child: Center(
            child: Card(
              margin: const EdgeInsets.symmetric(horizontal: 40),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 16),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: progress > 0 && progress < 1 ? progress : null,
                        minHeight: 8,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      progress > 0 ? Formatters.percent(progress) : 'Preparing…',
                      style: theme.textTheme.labelMedium,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
