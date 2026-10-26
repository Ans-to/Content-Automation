import '../core/constants.dart';

/// The decision taken for the current state of the queue.
class SchedulerPlan {
  const SchedulerPlan({
    required this.now,
    required this.nextDue,
    required this.hasActiveUploads,
    required this.exactAlarmsAvailable,
    required this.keepServiceRunning,
    required this.wakeupAt,
    required this.fallbackDelay,
  });

  /// Reference time the plan was computed for.
  final DateTime now;

  /// Earliest scheduled (not yet processed) upload, overdue ones included.
  final DateTime? nextDue;

  /// Something is being uploaded right now.
  final bool hasActiveUploads;

  final bool exactAlarmsAvailable;

  /// The foreground service should be (kept) running.
  final bool keepServiceRunning;

  /// When the exact alarm should fire (null = no alarm needed).
  final DateTime? wakeupAt;

  /// Delay for the WorkManager one-off safety net (null = cancel it).
  final Duration? fallbackDelay;

  bool get hasPendingWork => nextDue != null || hasActiveUploads;

  /// Time left until [nextDue] (zero when overdue), null when idle.
  Duration? get untilNextDue {
    final due = nextDue;
    if (due == null) return null;
    final diff = due.difference(now);
    return diff.isNegative ? Duration.zero : diff;
  }

  SchedulerPlan copyWith({bool? keepServiceRunning}) => SchedulerPlan(
    now: now,
    nextDue: nextDue,
    hasActiveUploads: hasActiveUploads,
    exactAlarmsAvailable: exactAlarmsAvailable,
    keepServiceRunning: keepServiceRunning ?? this.keepServiceRunning,
    wakeupAt: wakeupAt,
    fallbackDelay: fallbackDelay,
  );

  @override
  String toString() =>
      'SchedulerPlan(nextDue: $nextDue, active: $hasActiveUploads, '
      'keepService: $keepServiceRunning, wakeupAt: $wakeupAt, '
      'fallbackDelay: $fallbackDelay)';
}

/// Decides when the service must run and when to arm the wake-up alarm.
///
/// The idea: don't burn battery with a 24/7 foreground service. Sleep until an
/// exact alarm wakes the service [exactLead] before the due time; the service
/// then counts down with a precise timer. Without exact alarms the lead is
/// longer because the OS may deliver the alarm late.
class SchedulerPolicy {
  const SchedulerPolicy({
    this.exactLead = AppConstants.exactWakeupLead,
    this.inexactLead = AppConstants.inexactWakeupLead,
    this.fallbackLead = AppConstants.fallbackWakeupLead,
  });

  final Duration exactLead;
  final Duration inexactLead;
  final Duration fallbackLead;

  SchedulerPlan plan({
    required DateTime now,
    required DateTime? nextDue,
    required bool hasActiveUploads,
    required bool exactAlarmsAvailable,
  }) {
    final lead = exactAlarmsAvailable ? exactLead : inexactLead;

    final dueSoon = nextDue != null && nextDue.difference(now) <= lead;
    final keepServiceRunning = hasActiveUploads || dueSoon;

    // Alarm only when the due time is beyond the lead window.
    final wakeupAt = (nextDue != null && !dueSoon)
        ? nextDue.subtract(lead)
        : null;

    Duration? fallbackDelay;
    if (nextDue != null) {
      final delay = nextDue.difference(now) - fallbackLead;
      fallbackDelay = delay.isNegative ? Duration.zero : delay;
    }

    return SchedulerPlan(
      now: now,
      nextDue: nextDue,
      hasActiveUploads: hasActiveUploads,
      exactAlarmsAvailable: exactAlarmsAvailable,
      keepServiceRunning: keepServiceRunning,
      wakeupAt: wakeupAt,
      fallbackDelay: fallbackDelay,
    );
  }
}
