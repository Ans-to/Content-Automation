import 'package:content_automation/background/scheduler_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const policy = SchedulerPolicy(
    exactLead: Duration(minutes: 2),
    inexactLead: Duration(minutes: 20),
    fallbackLead: Duration(minutes: 15),
  );
  final now = DateTime(2026, 10, 26, 12, 0);

  test('idle queue: no service, no alarm, no fallback', () {
    final plan = policy.plan(
      now: now,
      nextDue: null,
      hasActiveUploads: false,
      exactAlarmsAvailable: true,
    );
    expect(plan.keepServiceRunning, isFalse);
    expect(plan.wakeupAt, isNull);
    expect(plan.fallbackDelay, isNull);
    expect(plan.hasPendingWork, isFalse);
    expect(plan.untilNextDue, isNull);
  });

  test('far-away upload: sleep until an exact alarm shortly before', () {
    final due = now.add(const Duration(hours: 3));
    final plan = policy.plan(
      now: now,
      nextDue: due,
      hasActiveUploads: false,
      exactAlarmsAvailable: true,
    );
    expect(plan.keepServiceRunning, isFalse);
    expect(plan.wakeupAt, due.subtract(const Duration(minutes: 2)));
    expect(
      plan.fallbackDelay,
      const Duration(hours: 3) - const Duration(minutes: 15),
    );
    expect(plan.untilNextDue, const Duration(hours: 3));
  });

  test('without exact alarms the lead window is much longer', () {
    final due = now.add(const Duration(minutes: 10));
    final plan = policy.plan(
      now: now,
      nextDue: due,
      hasActiveUploads: false,
      exactAlarmsAvailable: false,
    );
    // 10 min away is inside the 20 min inexact lead → keep the service up.
    expect(plan.keepServiceRunning, isTrue);
    expect(plan.wakeupAt, isNull);

    final far = policy.plan(
      now: now,
      nextDue: now.add(const Duration(hours: 1)),
      hasActiveUploads: false,
      exactAlarmsAvailable: false,
    );
    expect(far.keepServiceRunning, isFalse);
    expect(far.wakeupAt, now.add(const Duration(minutes: 40)));
  });

  test('due soon or overdue: service must run now', () {
    final soon = policy.plan(
      now: now,
      nextDue: now.add(const Duration(seconds: 90)),
      hasActiveUploads: false,
      exactAlarmsAvailable: true,
    );
    expect(soon.keepServiceRunning, isTrue);
    expect(soon.wakeupAt, isNull);
    expect(soon.fallbackDelay, Duration.zero);

    final overdue = policy.plan(
      now: now,
      nextDue: now.subtract(const Duration(minutes: 5)),
      hasActiveUploads: false,
      exactAlarmsAvailable: true,
    );
    expect(overdue.keepServiceRunning, isTrue);
    expect(overdue.untilNextDue, Duration.zero);
    expect(overdue.fallbackDelay, Duration.zero);
  });

  test('an in-flight upload keeps the service alive even with an empty queue',
      () {
    final plan = policy.plan(
      now: now,
      nextDue: null,
      hasActiveUploads: true,
      exactAlarmsAvailable: true,
    );
    expect(plan.keepServiceRunning, isTrue);
    expect(plan.hasPendingWork, isTrue);
  });

  test('copyWith only overrides keepServiceRunning', () {
    final due = now.add(const Duration(hours: 1));
    final plan = policy.plan(
      now: now,
      nextDue: due,
      hasActiveUploads: false,
      exactAlarmsAvailable: true,
    );
    final forced = plan.copyWith(keepServiceRunning: true);
    expect(forced.keepServiceRunning, isTrue);
    expect(forced.wakeupAt, plan.wakeupAt);
    expect(forced.nextDue, due);
    expect(forced.toString(), contains('keepService: true'));
  });
}
