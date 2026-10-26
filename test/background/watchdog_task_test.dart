import 'package:content_automation/background/watchdog_task.dart';
import 'package:content_automation/data/models/enums.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/background_fakes.dart';

void main() {
  test('nothing due: only stamps the watchdog run', () async {
    final h = EngineHarness();
    await h.addUpload(inFuture: const Duration(hours: 4));

    final inline = await WatchdogTask(h.runtime, clock: h.clock.call)
        .run(trigger: 'watchdog');

    expect(inline, isFalse);
    expect(h.bridge.serviceStartRequests, 0);
    expect(h.statusStore.status?.lastWatchdogRun, h.clock.now);
    // The alarm was (re)armed on the way.
    expect(h.bridge.scheduledWakeup, isNotNull);
  });

  test('due soon and service down: starts the foreground service', () async {
    final h = EngineHarness();
    await h.addUpload(inFuture: const Duration(seconds: 30));

    final inline = await WatchdogTask(h.runtime, clock: h.clock.call)
        .run(trigger: 'watchdog');

    expect(inline, isFalse);
    expect(h.bridge.serviceStartRequests, 1);
    expect(h.bridge.serviceRunning, isTrue);
    // Nothing was processed here; the service takes over.
    expect(h.youtube.calls, isEmpty);
  });

  test('service already running: leaves it alone', () async {
    final h = EngineHarness();
    h.bridge.serviceRunning = true;
    await h.addUpload();

    await WatchdogTask(h.runtime, clock: h.clock.call).run(trigger: 'wakeup');

    expect(h.bridge.serviceStartRequests, 0);
    expect(h.youtube.calls, isEmpty);
  });

  test('service cannot start: processes due uploads inline', () async {
    final h = EngineHarness();
    h.bridge.canStartService = false;
    final created = await h.addUpload();

    final inline = await WatchdogTask(h.runtime, clock: h.clock.call)
        .run(trigger: 'wakeup');

    expect(inline, isTrue);
    expect(h.bridge.serviceStartRequests, 1);
    final upload = (await h.repository.getById(created.id!))!;
    expect(upload.status, UploadStatus.completed);
    expect(h.notifier.events, ['starting:${created.id}', 'completed:${created.id}']);
    // Queue is empty afterwards → alarm cleared.
    expect(h.bridge.scheduledWakeup, isNull);
  });

  test('recovers interrupted uploads before anything else', () async {
    final h = EngineHarness(now: DateTime.now());
    final created = await h.addUpload();
    await h.repository.updateStatus(created.id!, status: UploadStatus.uploading);
    h.clock.advance(const Duration(hours: 1));

    await WatchdogTask(h.runtime, clock: h.clock.call).run(trigger: 'watchdog');

    expect((await h.repository.getById(created.id!))!.status, UploadStatus.failed);
    expect(h.bridge.serviceStartRequests, 0);
  });
}
