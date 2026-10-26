import 'dart:async';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import '../core/constants.dart';
import '../core/utils/formatters.dart';
import 'background_runtime.dart';
import 'scheduler_policy.dart';
import 'scheduler_status.dart';
import 'upload_engine.dart';

/// Entry point of the foreground service isolate (flutter_background_service).
///
/// Must stay a top-level function with the `vm:entry-point` pragma so the
/// native side can find it after the app process was killed and restarted.
@pragma('vm:entry-point')
Future<void> onSchedulerServiceStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  final runtime = await BackgroundRuntime.create();
  final session = SchedulerServiceSession(service: service, runtime: runtime);
  await session.start();
}

/// The loop that runs inside the foreground service:
///
///  1. process anything that is due,
///  2. re-plan wake-ups,
///  3. stop itself when nothing is due soon (the exact alarm will bring it
///     back), otherwise sleep with a precise timer until the next due time
///     (or the heartbeat, whichever is sooner).
class SchedulerServiceSession {
  SchedulerServiceSession({
    required this.service,
    required this.runtime,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final ServiceInstance service;
  final BackgroundRuntime runtime;
  final DateTime Function() _clock;

  final List<StreamSubscription<Object?>> _subscriptions = [];
  Timer? _timer;
  bool _ticking = false;
  bool _tickRequested = false;
  bool _stopping = false;

  DateTime? _lastPublishAt;
  String? _lastPublishedMessage;

  Future<void> start() async {
    _subscriptions.add(service.on('refresh').listen((_) => requestTick()));
    _subscriptions.add(service.on('stopService').listen((_) => stop()));
    runtime.engine.onActivity = _onActivity;

    await _publish(
      SchedulerStatus(
        state: SchedulerState.waiting,
        updatedAt: _clock(),
        source: 'service',
        message: 'Scheduler started',
      ),
    );

    try {
      final recovered = await runtime.engine.recoverInterrupted();
      if (recovered > 0) {
        debugPrint('Scheduler: marked $recovered interrupted upload(s) failed');
      }
    } catch (e) {
      debugPrint('Scheduler: recovery failed: $e');
    }

    await _tick();
  }

  /// Runs a pass as soon as possible (used when the schedule changed).
  void requestTick() {
    if (_stopping) return;
    if (_ticking) {
      _tickRequested = true;
      return;
    }
    _timer?.cancel();
    unawaited(_tick());
  }

  Future<void> _tick() async {
    if (_stopping || _ticking) return;
    _ticking = true;
    try {
      try {
        await runtime.engine.processDue();
      } catch (e, stack) {
        debugPrint('Scheduler: processing failed: $e\n$stack');
      }

      final SchedulerPlan plan;
      try {
        plan = await runtime.planner.replan();
      } catch (e) {
        debugPrint('Scheduler: re-plan failed: $e');
        _arm(AppConstants.serviceHeartbeat);
        return;
      }

      if (!plan.keepServiceRunning) {
        await _publish(_restingStatus(plan));
        await stop();
        return;
      }

      await _publish(_waitingStatus(plan));
      _arm(_delayFor(plan));
    } finally {
      _ticking = false;
      if (_tickRequested && !_stopping) {
        _tickRequested = false;
        requestTick();
      }
    }
  }

  void _arm(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, () => unawaited(_tick()));
  }

  Duration _delayFor(SchedulerPlan plan) {
    var delay = AppConstants.serviceHeartbeat;
    final until = plan.untilNextDue;
    if (until != null && until < delay) delay = until;
    // A hair after the due instant so the `<= now` query matches.
    return delay + const Duration(milliseconds: 20);
  }

  SchedulerStatus _waitingStatus(SchedulerPlan plan) {
    final now = _clock();
    final nextDue = plan.nextDue;
    final message = nextDue == null
        ? 'Finishing up…'
        : 'Next upload ${Formatters.countdown(nextDue, now: now)} '
              '(${Formatters.time(nextDue)})';
    return SchedulerStatus(
      state: SchedulerState.waiting,
      updatedAt: now,
      source: 'service',
      message: message,
      nextDue: nextDue,
    );
  }

  SchedulerStatus _restingStatus(SchedulerPlan plan) {
    final now = _clock();
    final nextDue = plan.nextDue;
    final kind = runtime.planner.lastWakeupKind;
    return SchedulerStatus(
      state: nextDue == null ? SchedulerState.idle : SchedulerState.sleeping,
      updatedAt: now,
      source: 'service',
      message: nextDue == null
          ? 'No uploads scheduled'
          : 'Sleeping; wake-up alarm set for '
                '${Formatters.time(plan.wakeupAt ?? nextDue)}',
      nextDue: nextDue,
      wakeupAt: plan.wakeupAt,
      wakeupKind: kind?.name,
    );
  }

  void _onActivity(EngineActivity activity) {
    final progress = activity.progress;
    final percent = progress == null ? '' : ' ${Formatters.percent(progress)}';
    unawaited(
      _publish(
        SchedulerStatus(
          state: SchedulerState.uploading,
          updatedAt: _clock(),
          source: 'service',
          message: '${activity.message}$percent',
          activeUploadId: activity.uploadId,
          activeTitle: activity.title,
          progress: progress,
        ),
        throttle: progress != null && progress < 1,
      ),
    );
  }

  Future<void> _publish(SchedulerStatus status, {bool throttle = false}) async {
    final now = _clock();
    if (throttle &&
        _lastPublishAt != null &&
        now.difference(_lastPublishAt!) < const Duration(seconds: 1) &&
        status.message == _lastPublishedMessage) {
      return;
    }
    _lastPublishAt = now;
    _lastPublishedMessage = status.message;

    try {
      service.invoke('status', status.toMap());
    } catch (_) {
      // No UI listening — fine.
    }

    final instance = service;
    if (instance is AndroidServiceInstance) {
      try {
        await instance.setForegroundNotificationInfo(
          title: _notificationTitle(status),
          content: status.message ?? status.state.label,
        );
      } catch (_) {
        // Notification updates are cosmetic.
      }
    }

    await runtime.statusStore.write(status);
  }

  String _notificationTitle(SchedulerStatus status) => switch (status.state) {
    SchedulerState.uploading =>
      'Uploading "${status.activeTitle ?? 'video'}"',
    SchedulerState.waiting => '${AppConstants.appName} · armed',
    SchedulerState.sleeping => '${AppConstants.appName} · sleeping',
    SchedulerState.idle => AppConstants.appName,
  };

  Future<void> stop() async {
    if (_stopping) return;
    _stopping = true;
    _timer?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    runtime.engine.onActivity = null;
    try {
      await runtime.dispose();
    } catch (_) {
      // Closing the database is best effort during shutdown.
    }
    await service.stopSelf();
  }
}
