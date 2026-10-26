import 'package:flutter/foundation.dart';

import 'background_runtime.dart';

/// The watchdog pass (pure Dart; unit tested with fakes).
class WatchdogTask {
  WatchdogTask(this.runtime, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final BackgroundRuntime runtime;
  final DateTime Function() _clock;

  /// Returns `true` when due uploads were processed inline (i.e. the service
  /// could not be started and this isolate did the work itself).
  Future<bool> run({required String trigger}) async {
    final engine = runtime.engine;
    final planner = runtime.planner;
    final bridge = runtime.bridge;

    var plan = await planner.replan();
    // Active uploads keep `plan.keepServiceRunning` true, so an interrupted
    // upload makes the watchdog (re)start the service, which resumes it on
    // start-up with the foreground-service time budget. Only when the service
    // cannot be started is the recovery done inline (WorkManager grants ~10
    // minutes, enough for small videos).

    var serviceRunning = false;
    try {
      serviceRunning = await bridge.isSchedulerServiceRunning();
    } catch (e) {
      debugPrint('Watchdog: could not query service state: $e');
    }

    var processedInline = false;
    if (plan.keepServiceRunning && !serviceRunning) {
      var started = false;
      try {
        started = await bridge.startSchedulerService();
      } catch (e) {
        debugPrint('Watchdog: service start failed: $e');
      }
      if (!started) {
        // Last resort: do the work in this isolate.
        await engine.recoverInterrupted();
        await engine.processDue();
        plan = await planner.replan();
        processedInline = true;
      }
    }

    // Catch up on WhatsApp "Status" requests between service runs.
    await runtime.pollInbox();

    await runtime.statusStore.markWatchdogRun(_clock());
    debugPrint(
      'Watchdog($trigger): $plan, serviceRunning=$serviceRunning, '
      'inline=$processedInline',
    );
    return processedInline;
  }
}
