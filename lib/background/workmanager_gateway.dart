import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

import '../core/constants.dart';

/// Thin seam over the `workmanager` plugin so the planner can be unit tested
/// and so WorkManager failures never bubble into the scheduling logic.
abstract interface class WorkmanagerGateway {
  /// Registers (or keeps) the periodic watchdog.
  Future<void> ensureWatchdog();

  /// (Re)arms the one-off safety-net task to run after [delay].
  Future<void> scheduleFallbackWakeup(Duration delay);

  Future<void> cancelFallbackWakeup();
}

/// Production gateway.
class WorkmanagerGatewayImpl implements WorkmanagerGateway {
  const WorkmanagerGatewayImpl();

  @override
  Future<void> ensureWatchdog() async {
    try {
      await Workmanager().registerPeriodicTask(
        AppConstants.watchdogTaskName,
        AppConstants.watchdogTaskName,
        frequency: AppConstants.watchdogInterval,
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
        backoffPolicy: BackoffPolicy.linear,
        backoffPolicyDelay: const Duration(minutes: 1),
      );
    } catch (e) {
      debugPrint('WorkManager watchdog registration failed: $e');
    }
  }

  @override
  Future<void> scheduleFallbackWakeup(Duration delay) async {
    try {
      await Workmanager().registerOneOffTask(
        AppConstants.wakeupTaskName,
        AppConstants.wakeupTaskName,
        initialDelay: delay,
        existingWorkPolicy: ExistingWorkPolicy.replace,
        backoffPolicy: BackoffPolicy.linear,
        backoffPolicyDelay: const Duration(minutes: 1),
      );
    } catch (e) {
      debugPrint('WorkManager fallback registration failed: $e');
    }
  }

  @override
  Future<void> cancelFallbackWakeup() async {
    try {
      await Workmanager().cancelByUniqueName(AppConstants.wakeupTaskName);
    } catch (e) {
      debugPrint('WorkManager fallback cancellation failed: $e');
    }
  }
}

/// Records calls (tests / platforms without WorkManager).
class RecordingWorkmanagerGateway implements WorkmanagerGateway {
  bool watchdogRegistered = false;
  Duration? fallbackDelay;
  int fallbackCancellations = 0;

  @override
  Future<void> ensureWatchdog() async {
    watchdogRegistered = true;
  }

  @override
  Future<void> scheduleFallbackWakeup(Duration delay) async {
    fallbackDelay = delay;
  }

  @override
  Future<void> cancelFallbackWakeup() async {
    fallbackDelay = null;
    fallbackCancellations++;
  }
}
