import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

import 'background_runtime.dart';
import 'watchdog_task.dart';

/// Entry point of the WorkManager isolate.
///
/// Two tasks share it: the periodic watchdog and the one-off "fallback
/// wake-up" that is armed shortly before each due time. Both do the same
/// thing — make sure the foreground service is up when it should be, and
/// process due uploads right here if the service cannot be started.
@pragma('vm:entry-point')
void workmanagerDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    DartPluginRegistrant.ensureInitialized();
    BackgroundRuntime? runtime;
    try {
      runtime = await BackgroundRuntime.create();
      await WatchdogTask(runtime).run(trigger: task);
      return true;
    } catch (e, stack) {
      debugPrint('Background task "$task" failed: $e\n$stack');
      return false;
    } finally {
      await runtime?.dispose();
    }
  });
}
