import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:platform_bridge/platform_bridge.dart';
import 'package:workmanager/workmanager.dart';

import '../core/constants.dart';
import '../core/utils/formatters.dart';
import '../data/repositories/schedule_repository.dart';
import 'scheduler_service.dart';
import 'scheduler_status.dart';
import 'wakeup_planner.dart';
import 'workmanager_gateway.dart';
import 'workmanager_tasks.dart';

/// What the UI isolate can do with the background machinery.
abstract interface class BackgroundController {
  /// Configures the service + WorkManager. Safe to call more than once.
  Future<void> initialize();

  /// Re-arms alarms / starts the service after the schedule changed.
  Future<void> syncSchedule();

  /// Live status updates coming from the service.
  Stream<SchedulerStatus> get statusStream;

  /// Last status persisted by any isolate (survives app restarts).
  Future<SchedulerStatus?> readLastStatus();

  Future<bool> isServiceRunning();

  /// Starts the foreground service right now (manual "Start" button).
  Future<void> startService();

  /// Asks the service to stop (it will come back on the next wake-up).
  Future<void> stopService();
}

/// Used in tests and on platforms without the Android plugins.
class NoopBackgroundController implements BackgroundController {
  NoopBackgroundController();

  final StreamController<SchedulerStatus> _controller =
      StreamController<SchedulerStatus>.broadcast();
  int syncCalls = 0;
  bool running = false;

  /// Lets tests push a status to listeners, as if the service sent it.
  void emit(SchedulerStatus status) {
    if (status.source == 'service') {
      running =
          status.state == SchedulerState.waiting ||
          status.state == SchedulerState.uploading;
    }
    _controller.add(status);
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<void> syncSchedule() async {
    syncCalls++;
  }

  @override
  Stream<SchedulerStatus> get statusStream => _controller.stream;

  @override
  Future<SchedulerStatus?> readLastStatus() async => null;

  @override
  Future<bool> isServiceRunning() async => running;

  @override
  Future<void> startService() async {
    running = true;
  }

  @override
  Future<void> stopService() async {
    running = false;
  }
}

/// Production controller (Android).
class BackgroundCoordinator implements BackgroundController {
  BackgroundCoordinator({
    required ScheduleRepository repository,
    required PlatformBridge bridge,
    WorkmanagerGateway workmanager = const WorkmanagerGatewayImpl(),
    FlutterBackgroundService? service,
    SchedulerStatusStore? statusStore,
  }) : _bridge = bridge,
       _workmanager = workmanager,
       _service = service ?? FlutterBackgroundService(),
       _statusStore = statusStore ?? FileSchedulerStatusStore(),
       _planner = WakeupPlanner(
         repository: repository,
         bridge: bridge,
         workmanager: workmanager,
       );

  static const List<NotificationChannelSpec> notificationChannels = [
    NotificationChannelSpec(
      id: AppConstants.schedulerChannelId,
      name: 'Upload scheduler',
      description:
          'Shown while the app waits for a scheduled time or uploads a video.',
      importance: NotificationImportance.low,
    ),
    NotificationChannelSpec(
      id: AppConstants.eventsChannelId,
      name: 'Upload events',
      description: 'Time reached, upload completed, upload failed.',
      importance: NotificationImportance.high,
    ),
  ];

  final PlatformBridge _bridge;
  final WorkmanagerGateway _workmanager;
  final FlutterBackgroundService _service;
  final SchedulerStatusStore _statusStore;
  final WakeupPlanner _planner;

  final StreamController<SchedulerStatus> _statusController =
      StreamController<SchedulerStatus>.broadcast();
  StreamSubscription<Map<String, dynamic>?>? _serviceSubscription;
  bool _initialized = false;
  bool _serviceConfigured = false;

  @override
  Stream<SchedulerStatus> get statusStream => _statusController.stream;

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    try {
      await _bridge.ensureNotificationChannels(notificationChannels);
    } catch (e) {
      debugPrint('Notification channels: $e');
    }

    try {
      _serviceConfigured = await _service.configure(
        iosConfiguration: IosConfiguration(autoStart: false),
        androidConfiguration: AndroidConfiguration(
          onStart: onSchedulerServiceStart,
          autoStart: false,
          autoStartOnBoot: true,
          isForegroundMode: true,
          notificationChannelId: AppConstants.schedulerChannelId,
          initialNotificationTitle: AppConstants.appName,
          initialNotificationContent: 'Checking the upload schedule…',
          foregroundServiceNotificationId: AppConstants.foregroundNotificationId,
          foregroundServiceTypes: const [AndroidForegroundType.specialUse],
        ),
      );
      _serviceSubscription = _service.on('status').listen((event) {
        if (event == null) return;
        try {
          _statusController.add(SchedulerStatus.fromMap(event));
        } catch (e) {
          debugPrint('Bad status payload: $e');
        }
      });
    } catch (e) {
      debugPrint('Background service configuration failed: $e');
    }

    try {
      await Workmanager().initialize(workmanagerDispatcher);
      await _workmanager.ensureWatchdog();
    } catch (e) {
      debugPrint('WorkManager initialisation failed: $e');
    }

    await syncSchedule();
  }

  @override
  Future<void> syncSchedule() async {
    try {
      final plan = await _planner.replan();
      final running = await isServiceRunning();
      if (plan.keepServiceRunning) {
        if (running) {
          _service.invoke('refresh');
        } else if (_serviceConfigured) {
          await _service.startService();
        }
        return;
      }
      if (running) {
        // Let the service re-evaluate; it stops itself when idle.
        _service.invoke('refresh');
      }
      // Record what the UI isolate decided so the status screen is accurate
      // even before the service ever ran.
      final nextDue = plan.nextDue;
      await _statusStore.write(
        SchedulerStatus(
          state: nextDue == null
              ? SchedulerState.idle
              : SchedulerState.sleeping,
          updatedAt: DateTime.now(),
          source: 'app',
          message: nextDue == null
              ? 'No uploads scheduled'
              : 'Wake-up alarm set for '
                    '${Formatters.time(plan.wakeupAt ?? nextDue)}',
          nextDue: nextDue,
          wakeupAt: plan.wakeupAt,
          wakeupKind: _planner.lastWakeupKind?.name,
        ),
      );
      final latest = await _statusStore.read();
      if (latest != null) _statusController.add(latest);
    } catch (e) {
      debugPrint('Schedule sync failed: $e');
    }
  }

  @override
  Future<SchedulerStatus?> readLastStatus() => _statusStore.read();

  @override
  Future<bool> isServiceRunning() async {
    try {
      return await _service.isRunning();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> startService() async {
    if (!_serviceConfigured) return;
    try {
      if (await _service.isRunning()) {
        _service.invoke('refresh');
      } else {
        await _service.startService();
      }
    } catch (e) {
      debugPrint('Could not start the scheduler service: $e');
    }
  }

  @override
  Future<void> stopService() async {
    try {
      _service.invoke('stopService');
    } catch (e) {
      debugPrint('Could not stop the scheduler service: $e');
    }
  }

  void dispose() {
    _serviceSubscription?.cancel();
    _statusController.close();
  }
}
