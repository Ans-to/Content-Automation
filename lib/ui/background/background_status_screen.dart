import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../background/scheduler_status.dart';
import '../../core/constants.dart';
import '../../core/utils/formatters.dart';
import '../../state/background_provider.dart';
import '../widgets/section_header.dart';

/// Shows what the scheduler is doing and walks the user through the Android
/// permissions needed for uploads to start while the app is closed.
class BackgroundStatusScreen extends StatefulWidget {
  const BackgroundStatusScreen({super.key});

  @override
  State<BackgroundStatusScreen> createState() => _BackgroundStatusScreenState();
}

class _BackgroundStatusScreenState extends State<BackgroundStatusScreen>
    with WidgetsBindingObserver {
  Timer? _clock;
  DateTime _now = DateTime.now();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _clock = Timer.periodic(AppConstants.countdownRefreshInterval, (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(context.read<BackgroundProvider>().refresh());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clock?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from a system settings screen: re-check everything.
    if (state == AppLifecycleState.resumed && mounted) {
      unawaited(context.read<BackgroundProvider>().refresh());
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _fix(
    BackgroundProvider provider,
    BackgroundRequirement requirement,
  ) {
    return _run(() async {
      switch (requirement) {
        case BackgroundRequirement.batteryOptimization:
          await provider.requestBatteryExemption();
        case BackgroundRequirement.notifications:
          final granted = await provider.requestNotifications();
          if (!granted && provider.notificationsEnabled == false) {
            // Permanently denied → only the system screen can fix it.
            await provider.openAppSettings();
          }
        case BackgroundRequirement.exactAlarms:
          await provider.requestExactAlarms();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<BackgroundProvider>();
    final status = provider.status;
    final missing = provider.missingRequirements;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Background execution'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _busy ? null : () => _run(provider.refresh),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: provider.refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            if (provider.error case final error?)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SectionHeader(title: 'SCHEDULER'),
            _StatusCard(
              status: status,
              serviceRunning: provider.serviceRunning,
              now: _now,
              busy: _busy,
              onStart: () => _run(provider.startService),
              onStop: () => _run(provider.stopService),
            ),
            SectionHeader(
              title: 'HEALTH CHECKS',
              count: missing.isEmpty ? null : missing.length,
            ),
            if (!provider.isLoaded)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              if (missing.isEmpty)
                const _AllGoodBanner()
              else
                for (final requirement in missing)
                  _RequirementCard(
                    requirement: requirement,
                    busy: _busy,
                    onFix: () => _fix(provider, requirement),
                    onOpenSettings:
                        requirement == BackgroundRequirement.batteryOptimization
                        ? () => _run(provider.openBatterySettings)
                        : null,
                  ),
              for (final requirement in BackgroundRequirement.values)
                if (provider.isSatisfied(requirement))
                  ListTile(
                    leading: Icon(
                      Icons.check_circle,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    title: Text(requirement.title),
                    subtitle: const Text('Granted'),
                    dense: true,
                  ),
              if (provider.vendorNeedsAutoStart)
                _VendorCard(
                  vendor: provider.deviceInfo.vendorLabel,
                  busy: _busy,
                  onOpen: () => _run(provider.openAutoStartSettings),
                ),
            ],
            const SectionHeader(title: 'HOW IT WORKS'),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 0),
              child: Text(
                '• Videos never leave this phone before the scheduled time.\n'
                '• An exact alarm wakes the app a couple of minutes early, '
                'starts a small foreground service (visible as a quiet '
                'notification) and, at the exact time, sends the WhatsApp '
                '"Time reached" message and starts the uploads.\n'
                '• A WorkManager watchdog runs every 15 minutes as a safety '
                'net in case the alarm was suppressed.\n'
                '• When nothing is due soon the service shuts itself down so '
                'no battery is used.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.status,
    required this.serviceRunning,
    required this.now,
    required this.busy,
    required this.onStart,
    required this.onStop,
  });

  final SchedulerStatus? status;
  final bool serviceRunning;
  final DateTime now;
  final bool busy;
  final VoidCallback onStart;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = status?.state ?? SchedulerState.idle;
    final (icon, color) = switch (state) {
      SchedulerState.idle => (Icons.pause_circle_outline, scheme.outline),
      SchedulerState.sleeping => (Icons.alarm, scheme.tertiary),
      SchedulerState.waiting => (Icons.hourglass_top, scheme.primary),
      SchedulerState.uploading => (Icons.cloud_upload, scheme.primary),
    };
    final progress = status?.progress;
    final nextDue = status?.nextDue;
    final wakeupAt = status?.wakeupAt;

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 32),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        state.label,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (status?.message case final message?)
                        Text(message, style: theme.textTheme.bodyMedium),
                      if (status == null)
                        Text(
                          'The scheduler has not reported yet.',
                          style: theme.textTheme.bodyMedium,
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (state == SchedulerState.uploading) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: progress),
              if (status?.activeTitle case final title?)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '$title · ${Formatters.percent(progress ?? 0)}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
            ],
            const Divider(height: 24),
            _InfoRow(
              label: 'Next due',
              value: nextDue == null
                  ? '—'
                  : '${Formatters.dateTime(nextDue)} '
                        '(${Formatters.countdown(nextDue, now: now)})',
            ),
            _InfoRow(
              label: 'Wake-up alarm',
              value: wakeupAt == null
                  ? '—'
                  : '${Formatters.dateTime(wakeupAt)} '
                        '· ${_wakeupKindLabel(status?.wakeupKind)}',
            ),
            _InfoRow(
              label: 'Foreground service',
              value: serviceRunning ? 'Running' : 'Stopped',
            ),
            _InfoRow(
              label: 'Last watchdog run',
              value: status?.lastWatchdogRun == null
                  ? 'Not yet'
                  : Formatters.dateTime(status!.lastWatchdogRun!),
            ),
            _InfoRow(
              label: 'Last update',
              value: status == null
                  ? '—'
                  : '${Formatters.dateTime(status!.updatedAt)} '
                        '(${status!.source})',
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                if (serviceRunning)
                  OutlinedButton.icon(
                    onPressed: busy ? null : onStop,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('Stop service'),
                  )
                else
                  FilledButton.tonalIcon(
                    onPressed: busy ? null : onStart,
                    icon: const Icon(Icons.play_circle_outline),
                    label: const Text('Start service now'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _wakeupKindLabel(String? kind) => switch (kind) {
    'exact' => 'exact alarm',
    'inexact' => 'inexact alarm (±10 min)',
    'unavailable' => 'WorkManager only',
    _ => 'alarm',
  };
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

class _AllGoodBanner extends StatelessWidget {
  const _AllGoodBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      color: scheme.primaryContainer,
      child: ListTile(
        leading: Icon(Icons.verified, color: scheme.onPrimaryContainer),
        title: Text(
          'Background execution allowed',
          style: TextStyle(
            color: scheme.onPrimaryContainer,
            fontWeight: FontWeight.w700,
          ),
        ),
        subtitle: Text(
          'Scheduled uploads can start even when the app is closed.',
          style: TextStyle(color: scheme.onPrimaryContainer),
        ),
      ),
    );
  }
}

class _RequirementCard extends StatelessWidget {
  const _RequirementCard({
    required this.requirement,
    required this.busy,
    required this.onFix,
    this.onOpenSettings,
  });

  final BackgroundRequirement requirement;
  final bool busy;
  final VoidCallback onFix;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = requirement.critical ? scheme.error : scheme.tertiary;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  requirement.critical
                      ? Icons.error_outline
                      : Icons.info_outline,
                  color: color,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    requirement.title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  requirement.critical ? 'Required' : 'Recommended',
                  style: theme.textTheme.labelSmall?.copyWith(color: color),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(requirement.explanation, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (onOpenSettings != null)
                  TextButton(
                    onPressed: busy ? null : onOpenSettings,
                    child: const Text('Battery settings'),
                  ),
                FilledButton(
                  onPressed: busy ? null : onFix,
                  child: const Text('Allow'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _VendorCard extends StatelessWidget {
  const _VendorCard({
    required this.vendor,
    required this.busy,
    required this.onOpen,
  });

  final String vendor;
  final bool busy;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$vendor phones need one more step',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '$vendor adds its own battery manager that can stop apps '
              'regardless of the Android setting above. In the screen that '
              'opens, enable "Auto-start" (or "Allow background activity" / '
              '"No restrictions") for ${AppConstants.appName}, and lock the '
              'app in the recent-apps list.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: busy ? null : onOpen,
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open auto-start settings'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
