import 'package:flutter/foundation.dart';
import 'package:platform_bridge/platform_bridge.dart';

import '../data/repositories/schedule_repository.dart';
import 'scheduler_policy.dart';
import 'workmanager_gateway.dart';

/// Looks at the queue and arms (or disarms) the OS-level wake-ups.
///
/// Called after every change to the schedule (UI isolate), after every
/// processing pass (service isolate) and from the WorkManager watchdog, so the
/// alarm always reflects the current "next due" time.
class WakeupPlanner {
  WakeupPlanner({
    required ScheduleRepository repository,
    required PlatformBridge bridge,
    required WorkmanagerGateway workmanager,
    SchedulerPolicy policy = const SchedulerPolicy(),
    DateTime Function()? clock,
  }) : _repository = repository,
       _bridge = bridge,
       _workmanager = workmanager,
       _policy = policy,
       _clock = clock ?? DateTime.now;

  final ScheduleRepository _repository;
  final PlatformBridge _bridge;
  final WorkmanagerGateway _workmanager;
  final SchedulerPolicy _policy;
  final DateTime Function() _clock;

  /// The last wake-up kind the OS granted (for diagnostics).
  WakeupKind? lastWakeupKind;

  Future<SchedulerPlan> replan() async {
    final now = _clock();

    final overdue = await _repository.getDue(now: now);
    final upcoming = await _repository.getNextScheduled(now: now);
    final active = await _repository.getActive();
    final nextDue = overdue.isNotEmpty
        ? overdue.first.scheduledTime
        : upcoming?.scheduledTime;

    var exactAlarms = false;
    try {
      exactAlarms = await _bridge.canScheduleExactAlarms();
    } catch (e) {
      debugPrint('canScheduleExactAlarms failed: $e');
    }

    var plan = _policy.plan(
      now: now,
      nextDue: nextDue,
      hasActiveUploads: active.isNotEmpty,
      exactAlarmsAvailable: exactAlarms,
    );

    // --- Exact alarm ----------------------------------------------------------
    final wakeupAt = plan.wakeupAt;
    try {
      if (wakeupAt != null) {
        lastWakeupKind = await _bridge.scheduleWakeup(wakeupAt);
        if (lastWakeupKind == WakeupKind.unavailable) {
          // No alarm at all: the only safe option is to keep the service up.
          plan = plan.copyWith(keepServiceRunning: true);
        }
      } else {
        await _bridge.cancelWakeup();
        lastWakeupKind = null;
      }
    } catch (e) {
      debugPrint('Wake-up alarm update failed: $e');
    }

    // --- WorkManager safety net -----------------------------------------------
    final delay = plan.fallbackDelay;
    if (delay != null) {
      await _workmanager.scheduleFallbackWakeup(delay);
    } else {
      await _workmanager.cancelFallbackWakeup();
    }

    return plan;
  }
}
