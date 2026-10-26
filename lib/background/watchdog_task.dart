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

    await engine.recoverInterrupted();
    var plan = await planner.replan();

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
        // Last resort: do the work in this isolate (WorkManager grants ~10
        // minutes, plenty for notifications and short uploads).
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
