import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:platform_bridge/platform_bridge.dart';

import '../background/background_coordinator.dart';
import '../background/scheduler_status.dart';

/// One item of the "background execution" checklist.
enum BackgroundRequirement {
  batteryOptimization(
    'Ignore battery optimisations',
    'Without this Android may freeze the app before the scheduled time. '
        'Required for uploads to start while the screen is off.',
    critical: true,
  ),
  notifications(
    'Allow notifications',
    'Needed to show the "Time reached" and "Upload failed" alerts (and the '
        'small status notification while an upload is running).',
    critical: true,
  ),
  exactAlarms(
    'Exact alarms',
    'Lets the app wake up at the exact minute you picked instead of whenever '
        'the system gets around to it.',
    critical: false,
  );

  const BackgroundRequirement(
    this.title,
    this.explanation, {
    required this.critical,
  });

  final String title;
  final String explanation;

  /// Critical items block reliable operation; others degrade precision.
  final bool critical;
}

/// Permission / health state of the background scheduler for the UI.
class BackgroundProvider extends ChangeNotifier {
  BackgroundProvider({
    required PlatformBridge bridge,
    required BackgroundController controller,
  }) : _bridge = bridge,
       _controller = controller {
    _subscription = _controller.statusStream.listen(_onStatus);
  }

  final PlatformBridge _bridge;
  final BackgroundController _controller;
  StreamSubscription<SchedulerStatus>? _subscription;

  bool _isLoaded = false;
  bool _refreshing = false;
  DeviceInfo _deviceInfo = DeviceInfo.unknown;
  bool? _batteryOptimizationIgnored;
  bool? _notificationsEnabled;
  bool? _exactAlarmsAllowed;
  bool _serviceRunning = false;
  SchedulerStatus? _status;
  String? _error;

  bool get isLoaded => _isLoaded;
  DeviceInfo get deviceInfo => _deviceInfo;
  bool? get batteryOptimizationIgnored => _batteryOptimizationIgnored;
  bool? get notificationsEnabled => _notificationsEnabled;
  bool? get exactAlarmsAllowed => _exactAlarmsAllowed;
  bool get serviceRunning => _serviceRunning;
  SchedulerStatus? get status => _status;
  String? get error => _error;

  bool isSatisfied(BackgroundRequirement requirement) => switch (requirement) {
    BackgroundRequirement.batteryOptimization =>
      _batteryOptimizationIgnored ?? true,
    BackgroundRequirement.notifications => _notificationsEnabled ?? true,
    BackgroundRequirement.exactAlarms => _exactAlarmsAllowed ?? true,
  };

  List<BackgroundRequirement> get missingRequirements => BackgroundRequirement
      .values
      .where((r) => !isSatisfied(r))
      .toList(growable: false);

  /// A critical requirement is missing — the home screen shows a banner.
  bool get needsAttention =>
      _isLoaded && missingRequirements.any((r) => r.critical);

  int get issueCount => missingRequirements.length;

  /// Vendor-specific "auto-start" whitelisting is probably needed too.
  bool get vendorNeedsAutoStart => _deviceInfo.hasAggressiveBatteryManager;

  Future<void> refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      _deviceInfo = await _bridge.getDeviceInfo();
      _batteryOptimizationIgnored = await _bridge
          .isIgnoringBatteryOptimizations();
      _notificationsEnabled = await _bridge.areNotificationsEnabled();
      _exactAlarmsAllowed = await _bridge.canScheduleExactAlarms();
      _serviceRunning = await _controller.isServiceRunning();
      _status = await _controller.readLastStatus() ?? _status;
      _error = null;
    } catch (e) {
      _error = 'Could not read background status: $e';
    } finally {
      _isLoaded = true;
      _refreshing = false;
      notifyListeners();
    }
  }

  // --- Actions ---------------------------------------------------------------

  // Each request is followed by a refresh: on a phone the system dialog
  // pauses/resumes the app (the screen refreshes on resume as well), in tests
  // and on fast paths this keeps the flags consistent immediately.

  Future<void> requestBatteryExemption() async {
    await _guard(() => _bridge.requestIgnoreBatteryOptimizations());
    await refresh();
  }

  Future<void> openBatterySettings() async {
    await _guard(() => _bridge.openBatteryOptimizationSettings());
  }

  Future<bool> requestNotifications() async {
    final granted = await _guard(() => _bridge.requestNotificationPermission());
    await refresh();
    return granted ?? false;
  }

  Future<void> requestExactAlarms() async {
    await _guard(() => _bridge.requestExactAlarmPermission());
    await refresh();
  }

  Future<void> openAutoStartSettings() async {
    final opened = await _guard(() => _bridge.openAutoStartSettings());
    if (opened != true) {
      await _guard(() => _bridge.openAppSettings());
    }
  }

  Future<void> openAppSettings() async {
    await _guard(() => _bridge.openAppSettings());
  }

  Future<void> startService() async {
    await _controller.startService();
    // Give the native side a moment to flip isRunning().
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await refresh();
  }

  Future<void> stopService() async {
    await _controller.stopService();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await refresh();
  }

  Future<void> syncSchedule() => _controller.syncSchedule();

  Future<T?> _guard<T>(Future<T> Function() action) async {
    try {
      final result = await action();
      _error = null;
      return result;
    } catch (e) {
      _error = '$e';
      notifyListeners();
      return null;
    }
  }

  void _onStatus(SchedulerStatus status) {
    _status = status;
    _serviceRunning = switch (status.state) {
      SchedulerState.waiting || SchedulerState.uploading => true,
      SchedulerState.idle || SchedulerState.sleeping =>
        status.source == 'service' ? false : _serviceRunning,
    };
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
