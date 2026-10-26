import 'package:content_automation/background/wakeup_planner.dart';
import 'package:content_automation/background/workmanager_gateway.dart';
import 'package:content_automation/data/models/enums.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:platform_bridge/platform_bridge.dart';

import '../helpers/background_fakes.dart';

void main() {
  test('empty queue disarms the alarm and the WorkManager fallback', () async {
    final h = EngineHarness();

    final plan = await h.planner.replan();

    expect(plan.keepServiceRunning, isFalse);
    expect(h.bridge.scheduledWakeup, isNull);
    expect(h.bridge.wakeupCancellations, 1);
    expect(h.workmanager.fallbackDelay, isNull);
    expect(h.workmanager.fallbackCancellations, 1);
    expect(h.planner.lastWakeupKind, isNull);
  });

  test('a future upload arms an exact alarm 2 minutes before it', () async {
    final h = EngineHarness();
    final created = await h.addUpload(inFuture: const Duration(hours: 3));

    final plan = await h.planner.replan();

    expect(plan.nextDue, created.scheduledTime);
    expect(plan.keepServiceRunning, isFalse);
    expect(
      h.bridge.scheduledWakeup,
      created.scheduledTime.subtract(const Duration(minutes: 2)),
    );
    expect(h.planner.lastWakeupKind, WakeupKind.exact);
    expect(
      h.workmanager.fallbackDelay,
      const Duration(hours: 3) - const Duration(minutes: 15),
    );
  });

  test('without exact alarm permission the inexact lead is used', () async {
    final h = EngineHarness();
    h.bridge.exactAlarmsAllowed = false;
    final created = await h.addUpload(inFuture: const Duration(hours: 3));

    await h.planner.replan();

    expect(
      h.bridge.scheduledWakeup,
      created.scheduledTime.subtract(const Duration(minutes: 20)),
    );
    expect(h.planner.lastWakeupKind, WakeupKind.inexact);
  });

  test('overdue work means: no alarm, service must run', () async {
    final h = EngineHarness();
    await h.addUpload();
    h.clock.advance(const Duration(minutes: 3));

    final plan = await h.planner.replan();

    expect(plan.keepServiceRunning, isTrue);
    expect(plan.untilNextDue, Duration.zero);
    expect(h.bridge.scheduledWakeup, isNull);
    expect(h.workmanager.fallbackDelay, Duration.zero);
  });

  test('the earliest of overdue and upcoming uploads wins', () async {
    final h = EngineHarness();
    final overdue = await h.addUpload(title: 'late');
    await h.addUpload(inFuture: const Duration(hours: 5), title: 'later');
    h.clock.advance(const Duration(minutes: 1));

    final plan = await h.planner.replan();
    expect(plan.nextDue, overdue.scheduledTime);
  });

  test('when no alarm facility exists the service is kept alive', () async {
    final bridge = NoAlarmPlatformBridge();
    final harness = EngineHarness();
    final planner = WakeupPlanner(
      repository: harness.repository,
      bridge: bridge,
      workmanager: RecordingWorkmanagerGateway(),
      clock: harness.clock.call,
    );
    await harness.addUpload(inFuture: const Duration(hours: 2));

    final plan = await planner.replan();

    expect(planner.lastWakeupKind, WakeupKind.unavailable);
    expect(plan.keepServiceRunning, isTrue);
  });

  test('an in-flight upload keeps the service running', () async {
    final h = EngineHarness();
    final created = await h.addUpload(inFuture: const Duration(hours: 1));
    await h.repository.updateStatus(created.id!, status: UploadStatus.uploading);

    final plan = await h.planner.replan();

    expect(plan.hasActiveUploads, isTrue);
    expect(plan.keepServiceRunning, isTrue);
    expect(plan.nextDue, isNull);
  });
}
