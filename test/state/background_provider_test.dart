import 'package:content_automation/background/background_coordinator.dart';
import 'package:content_automation/background/scheduler_status.dart';
import 'package:content_automation/state/background_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:platform_bridge/platform_bridge.dart';

import '../helpers/background_fakes.dart';

void main() {
  late InMemoryPlatformBridge bridge;
  late NoopBackgroundController controller;
  late BackgroundProvider provider;

  setUp(() {
    bridge = InMemoryPlatformBridge();
    controller = NoopBackgroundController();
    provider = BackgroundProvider(bridge: bridge, controller: controller);
  });

  tearDown(() => provider.dispose());

  test('is quiet until the first refresh completes', () {
    expect(provider.isLoaded, isFalse);
    expect(provider.needsAttention, isFalse);
    expect(provider.issueCount, 0);
  });

  test('all permissions granted → nothing to fix', () async {
    await provider.refresh();
    expect(provider.isLoaded, isTrue);
    expect(provider.needsAttention, isFalse);
    expect(provider.missingRequirements, isEmpty);
    expect(provider.batteryOptimizationIgnored, isTrue);
  });

  test('battery optimisation or notifications missing need attention',
      () async {
    bridge.ignoringBatteryOptimizations = false;
    await provider.refresh();
    expect(provider.needsAttention, isTrue);
    expect(provider.missingRequirements, [
      BackgroundRequirement.batteryOptimization,
    ]);

    bridge
      ..ignoringBatteryOptimizations = true
      ..notificationsEnabled = false
      ..exactAlarmsAllowed = false;
    await provider.refresh();
    expect(provider.needsAttention, isTrue);
    expect(provider.issueCount, 2);
  });

  test('missing exact alarms alone is only a recommendation', () async {
    bridge.exactAlarmsAllowed = false;
    await provider.refresh();
    expect(provider.needsAttention, isFalse);
    expect(provider.issueCount, 1);
    expect(
      provider.isSatisfied(BackgroundRequirement.exactAlarms),
      isFalse,
    );
    expect(BackgroundRequirement.exactAlarms.critical, isFalse);
  });

  test('requesting permissions opens the system screens', () async {
    bridge.ignoringBatteryOptimizations = false;
    await provider.refresh();

    await provider.requestBatteryExemption();
    await provider.requestExactAlarms();
    await provider.openAutoStartSettings();
    final granted = await provider.requestNotifications();

    expect(granted, isTrue);
    expect(bridge.openedScreens, [
      'battery',
      'exact-alarms',
      'auto-start',
      'notifications',
    ]);
  });

  test('vendor hint shows for aggressive OEMs only', () async {
    bridge.deviceInfo = const DeviceInfo(
      manufacturer: 'Xiaomi',
      brand: 'Redmi',
      model: 'Note 12',
      sdkInt: 34,
      release: '14',
    );
    await provider.refresh();
    expect(provider.vendorNeedsAutoStart, isTrue);
    expect(provider.deviceInfo.vendorLabel, 'Xiaomi');

    bridge.deviceInfo = const DeviceInfo(
      manufacturer: 'Google',
      brand: 'google',
      model: 'Pixel 8',
      sdkInt: 35,
      release: '15',
    );
    await provider.refresh();
    expect(provider.vendorNeedsAutoStart, isFalse);
  });

  test('status events from the service update the running flag', () async {
    var notifications = 0;
    provider.addListener(() => notifications++);

    controller.emit(statusOf(SchedulerState.uploading));
    await Future<void>.delayed(Duration.zero);
    expect(provider.status?.state, SchedulerState.uploading);
    expect(provider.serviceRunning, isTrue);

    controller.emit(statusOf(SchedulerState.sleeping));
    await Future<void>.delayed(Duration.zero);
    expect(provider.serviceRunning, isFalse);

    // Status written by the UI isolate says nothing about the service.
    controller.emit(statusOf(SchedulerState.waiting));
    controller.emit(statusOf(SchedulerState.idle, source: 'app'));
    await Future<void>.delayed(Duration.zero);
    expect(provider.serviceRunning, isTrue);
    expect(notifications, 4);
  });

  test('start/stop go through the controller', () async {
    await provider.startService();
    expect(controller.running, isTrue);
    expect(provider.serviceRunning, isTrue);

    await provider.stopService();
    expect(controller.running, isFalse);
    expect(provider.serviceRunning, isFalse);
  });
}
