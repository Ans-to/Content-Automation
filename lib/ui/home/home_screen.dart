import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants.dart';
import '../../data/models/scheduled_upload.dart';
import '../../state/schedule_provider.dart';
import '../../state/settings_provider.dart';
import '../add_upload/add_upload_screen.dart';
import '../settings/settings_screen.dart';
import '../upload_detail/upload_detail_screen.dart';
import '../widgets/section_header.dart';
import 'widgets/empty_state.dart';
import 'widgets/upload_card.dart';

/// Main screen: the list of scheduled uploads.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Timer? _clock;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    // Keeps the "in 2h 15m" countdown labels fresh.
    _clock = Timer.periodic(AppConstants.countdownRefreshInterval, (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  Future<void> _openAdd() async {
    final created = await Navigator.of(context).push<ScheduledUpload>(
      MaterialPageRoute(builder: (_) => const AddUploadScreen()),
    );
    if (created != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Scheduled "${created.title}"')),
      );
    }
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
    );
  }

  void _openDetail(ScheduledUpload upload) {
    final id = upload.id;
    if (id == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => UploadDetailScreen(uploadId: id),
      ),
    );
  }

  Future<void> _delete(ScheduledUpload upload) async {
    final provider = context.read<ScheduleProvider>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await provider.delete(upload);
      messenger.showSnackBar(
        SnackBar(content: Text('Deleted "${upload.title}"')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not delete: $e')));
      await provider.load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final schedule = context.watch<ScheduleProvider>();
    final settings = context.watch<SettingsProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text(AppConstants.appName),
        actions: [
          IconButton(
            tooltip: 'Settings',
            onPressed: _openSettings,
            icon: Badge(
              isLabelVisible: settings.needsSetup,
              child: const Icon(Icons.settings_outlined),
            ),
          ),
        ],
      ),
      body: _buildBody(context, schedule, settings),
      floatingActionButton: schedule.uploads.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _openAdd,
              icon: const Icon(Icons.add),
              label: const Text('Schedule upload'),
            ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    ScheduleProvider schedule,
    SettingsProvider settings,
  ) {
    if (schedule.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final error = schedule.error;
    if (error != null && schedule.uploads.isEmpty) {
      return _ErrorView(message: error, onRetry: schedule.load);
    }

    if (schedule.uploads.isEmpty) {
      return RefreshIndicator(
        onRefresh: schedule.load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            if (settings.needsSetup)
              _SetupBanner(
                missing: settings.missingIntegrations,
                onOpenSettings: _openSettings,
              ),
            SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.6,
              child: EmptyState(onAdd: _openAdd),
            ),
          ],
        ),
      );
    }

    final upcoming = schedule.upcoming;
    final history = schedule.history;

    return RefreshIndicator(
      onRefresh: schedule.load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          if (settings.needsSetup)
            _SetupBanner(
              missing: settings.missingIntegrations,
              onOpenSettings: _openSettings,
            ),
          if (upcoming.isNotEmpty) ...[
            SectionHeader(title: 'UPCOMING', count: upcoming.length),
            for (final upload in upcoming)
              UploadCard(
                upload: upload,
                now: _now,
                onTap: () => _openDetail(upload),
                onDelete: () => _delete(upload),
              ),
          ],
          if (history.isNotEmpty) ...[
            SectionHeader(title: 'HISTORY', count: history.length),
            for (final upload in history)
              UploadCard(
                upload: upload,
                now: _now,
                onTap: () => _openDetail(upload),
                onDelete: () => _delete(upload),
              ),
          ],
        ],
      ),
    );
  }
}

class _SetupBanner extends StatelessWidget {
  const _SetupBanner({required this.missing, required this.onOpenSettings});

  final List<String> missing;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            Icon(Icons.key_outlined, color: scheme.onTertiaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'API keys needed',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: scheme.onTertiaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    'Not configured yet: ${missing.join(', ')}.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onTertiaryContainer,
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: onOpenSettings,
              child: const Text('Set up'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: scheme.error),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
