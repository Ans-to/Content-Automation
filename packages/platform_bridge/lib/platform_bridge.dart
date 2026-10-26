/// Dart side of the app-local Android plugin.
///
/// Everything here is reachable from the UI isolate as well as from the
/// background-service and WorkManager isolates (the plugin is registered in
/// every FlutterEngine the app creates).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What kind of wake-up alarm the OS actually accepted.
enum WakeupKind {
  /// Fires at the requested instant, even while the phone is dozing.
  exact,

  /// The OS may delay it (no exact-alarm permission). Callers should arm it
  /// earlier to compensate.
  inexact,

  /// Scheduling failed altogether.
  unavailable;

  static WakeupKind parse(Object? raw) => switch (raw) {
    'exact' => WakeupKind.exact,
    'inexact' => WakeupKind.inexact,
    _ => WakeupKind.unavailable,
  };
}

/// Importance of a notification channel (maps onto NotificationManager's).
enum NotificationImportance { min, low, normal, high }

/// Declarative description of a notification channel.
@immutable
class NotificationChannelSpec {
  const NotificationChannelSpec({
    required this.id,
    required this.name,
    required this.description,
    this.importance = NotificationImportance.normal,
  });

  final String id;
  final String name;
  final String description;
  final NotificationImportance importance;

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'description': description,
    'importance': switch (importance) {
      NotificationImportance.min => 'min',
      NotificationImportance.low => 'low',
      NotificationImportance.normal => 'default',
      NotificationImportance.high => 'high',
    },
  };
}

/// Basic facts about the phone, used for OEM-specific battery guidance.
@immutable
class DeviceInfo {
  const DeviceInfo({
    required this.manufacturer,
    required this.brand,
    required this.model,
    required this.sdkInt,
    required this.release,
  });

  factory DeviceInfo.fromMap(Map<Object?, Object?> map) => DeviceInfo(
    manufacturer: (map['manufacturer'] as String?) ?? '',
    brand: (map['brand'] as String?) ?? '',
    model: (map['model'] as String?) ?? '',
    sdkInt: (map['sdkInt'] as num?)?.toInt() ?? 0,
    release: (map['release'] as String?) ?? '',
  );

  static const DeviceInfo unknown = DeviceInfo(
    manufacturer: '',
    brand: '',
    model: '',
    sdkInt: 0,
    release: '',
  );

  final String manufacturer;
  final String brand;
  final String model;
  final int sdkInt;
  final String release;

  /// Vendors known to kill background services unless the app is whitelisted
  /// in a vendor-specific "auto-start" / "battery" screen.
  bool get hasAggressiveBatteryManager {
    final needle = '${manufacturer.toLowerCase()} ${brand.toLowerCase()}';
    const vendors = [
      'xiaomi',
      'redmi',
      'poco',
      'huawei',
      'honor',
      'oppo',
      'realme',
      'oneplus',
      'vivo',
      'iqoo',
      'samsung',
      'asus',
      'letv',
      'htc',
      'tecno',
      'infinix',
      'itel',
      'meizu',
    ];
    return vendors.any(needle.contains);
  }

  String get vendorLabel {
    if (manufacturer.isEmpty) return 'this phone';
    final m = manufacturer.trim();
    return m.isEmpty ? 'this phone' : m[0].toUpperCase() + m.substring(1);
  }
}

/// Native capabilities exposed by the plugin.
abstract interface class PlatformBridge {
  Future<DeviceInfo> getDeviceInfo();

  // Battery optimisation ("Ignore battery optimizations").
  Future<bool> isIgnoringBatteryOptimizations();
  Future<bool> requestIgnoreBatteryOptimizations();
  Future<bool> openBatteryOptimizationSettings();

  // Notifications.
  Future<bool> areNotificationsEnabled();
  Future<bool> requestNotificationPermission();
  Future<void> ensureNotificationChannels(List<NotificationChannelSpec> specs);
  Future<bool> showNotification({
    required int id,
    required String channelId,
    required String title,
    required String body,
    bool ongoing = false,
    int? progress,
    int maxProgress = 100,
  });
  Future<void> cancelNotification(int id);

  // Exact alarms.
  Future<bool> canScheduleExactAlarms();
  Future<bool> requestExactAlarmPermission();
  Future<WakeupKind> scheduleWakeup(DateTime at);
  Future<void> cancelWakeup();

  // Scheduler service (flutter_background_service) control from any isolate.
  Future<bool> startSchedulerService();
  Future<bool> isSchedulerServiceRunning();

  // Settings screens.
  Future<bool> openAppSettings();
  Future<bool> openAutoStartSettings();
}

/// Production implementation talking to `PlatformBridgePlugin.kt`.
class MethodChannelPlatformBridge implements PlatformBridge {
  const MethodChannelPlatformBridge();

  static const MethodChannel _channel = MethodChannel(
    'com.contentautomation/platform_bridge',
  );

  Future<void> _invokeVoid(String method, [Map<String, Object?>? args]) =>
      _channel.invokeMethod<void>(method, args);

  Future<bool> _invokeBool(String method, [Map<String, Object?>? args]) async {
    final result = await _channel.invokeMethod<bool>(method, args);
    return result ?? false;
  }

  @override
  Future<DeviceInfo> getDeviceInfo() async {
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
      'getDeviceInfo',
    );
    return raw == null ? DeviceInfo.unknown : DeviceInfo.fromMap(raw);
  }

  @override
  Future<bool> isIgnoringBatteryOptimizations() =>
      _invokeBool('isIgnoringBatteryOptimizations');

  @override
  Future<bool> requestIgnoreBatteryOptimizations() =>
      _invokeBool('requestIgnoreBatteryOptimizations');

  @override
  Future<bool> openBatteryOptimizationSettings() =>
      _invokeBool('openBatteryOptimizationSettings');

  @override
  Future<bool> areNotificationsEnabled() =>
      _invokeBool('areNotificationsEnabled');

  @override
  Future<bool> requestNotificationPermission() =>
      _invokeBool('requestNotificationPermission');

  @override
  Future<void> ensureNotificationChannels(
    List<NotificationChannelSpec> specs,
  ) => _invokeVoid('ensureNotificationChannels', {
    'channels': specs.map((s) => s.toMap()).toList(growable: false),
  });

  @override
  Future<bool> showNotification({
    required int id,
    required String channelId,
    required String title,
    required String body,
    bool ongoing = false,
    int? progress,
    int maxProgress = 100,
  }) => _invokeBool('showNotification', {
    'id': id,
    'channelId': channelId,
    'title': title,
    'body': body,
    'ongoing': ongoing,
    'progress': progress,
    'maxProgress': maxProgress,
  });

  @override
  Future<void> cancelNotification(int id) =>
      _invokeVoid('cancelNotification', {'id': id});

  @override
  Future<bool> canScheduleExactAlarms() => _invokeBool('canScheduleExactAlarms');

  @override
  Future<bool> requestExactAlarmPermission() =>
      _invokeBool('requestExactAlarmPermission');

  @override
  Future<WakeupKind> scheduleWakeup(DateTime at) async {
    try {
      final raw = await _channel.invokeMethod<String>('scheduleWakeup', {
        'atEpochMillis': at.millisecondsSinceEpoch,
      });
      return WakeupKind.parse(raw);
    } on PlatformException {
      return WakeupKind.unavailable;
    }
  }

  @override
  Future<void> cancelWakeup() => _invokeVoid('cancelWakeup');

  @override
  Future<bool> startSchedulerService() => _invokeBool('startSchedulerService');

  @override
  Future<bool> isSchedulerServiceRunning() =>
      _invokeBool('isSchedulerServiceRunning');

  @override
  Future<bool> openAppSettings() => _invokeBool('openAppSettings');

  @override
  Future<bool> openAutoStartSettings() => _invokeBool('openAutoStartSettings');
}

/// Records calls instead of touching the OS. Used by tests and by code paths
/// that run on platforms without the native plugin.
class InMemoryPlatformBridge implements PlatformBridge {
  InMemoryPlatformBridge({
    this.ignoringBatteryOptimizations = true,
    this.notificationsEnabled = true,
    this.exactAlarmsAllowed = true,
    this.serviceRunning = false,
    this.deviceInfo = DeviceInfo.unknown,
  });

  bool ignoringBatteryOptimizations;
  bool notificationsEnabled;
  bool exactAlarmsAllowed;
  bool serviceRunning;
  DeviceInfo deviceInfo;

  /// Whether [startSchedulerService] should succeed.
  bool canStartService = true;

  /// Whether permission requests should behave as if the user accepted.
  bool grantOnRequest = true;

  DateTime? scheduledWakeup;
  int wakeupCancellations = 0;
  int serviceStartRequests = 0;
  final List<NotificationChannelSpec> channels = [];
  final List<Map<String, Object?>> shownNotifications = [];
  final List<int> cancelledNotifications = [];
  final List<String> openedScreens = [];

  @override
  Future<DeviceInfo> getDeviceInfo() async => deviceInfo;

  @override
  Future<bool> isIgnoringBatteryOptimizations() async =>
      ignoringBatteryOptimizations;

  @override
  Future<bool> requestIgnoreBatteryOptimizations() async {
    openedScreens.add('battery');
    if (grantOnRequest) ignoringBatteryOptimizations = true;
    return true;
  }

  @override
  Future<bool> openBatteryOptimizationSettings() async {
    openedScreens.add('battery-settings');
    return true;
  }

  @override
  Future<bool> areNotificationsEnabled() async => notificationsEnabled;

  @override
  Future<bool> requestNotificationPermission() async {
    openedScreens.add('notifications');
    if (grantOnRequest) notificationsEnabled = true;
    return notificationsEnabled;
  }

  @override
  Future<void> ensureNotificationChannels(
    List<NotificationChannelSpec> specs,
  ) async {
    channels
      ..clear()
      ..addAll(specs);
  }

  @override
  Future<bool> showNotification({
    required int id,
    required String channelId,
    required String title,
    required String body,
    bool ongoing = false,
    int? progress,
    int maxProgress = 100,
  }) async {
    shownNotifications.add({
      'id': id,
      'channelId': channelId,
      'title': title,
      'body': body,
      'ongoing': ongoing,
      'progress': progress,
    });
    return notificationsEnabled;
  }

  @override
  Future<void> cancelNotification(int id) async {
    cancelledNotifications.add(id);
  }

  @override
  Future<bool> canScheduleExactAlarms() async => exactAlarmsAllowed;

  @override
  Future<bool> requestExactAlarmPermission() async {
    openedScreens.add('exact-alarms');
    if (grantOnRequest) exactAlarmsAllowed = true;
    return exactAlarmsAllowed;
  }

  @override
  Future<WakeupKind> scheduleWakeup(DateTime at) async {
    scheduledWakeup = at;
    return exactAlarmsAllowed ? WakeupKind.exact : WakeupKind.inexact;
  }

  @override
  Future<void> cancelWakeup() async {
    scheduledWakeup = null;
    wakeupCancellations++;
  }

  @override
  Future<bool> startSchedulerService() async {
    serviceStartRequests++;
    if (canStartService) serviceRunning = true;
    return canStartService;
  }

  @override
  Future<bool> isSchedulerServiceRunning() async => serviceRunning;

  @override
  Future<bool> openAppSettings() async {
    openedScreens.add('app-settings');
    return true;
  }

  @override
  Future<bool> openAutoStartSettings() async {
    openedScreens.add('auto-start');
    return true;
  }
}
