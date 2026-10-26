import 'package:content_automation/app.dart';
import 'package:content_automation/background/background_coordinator.dart';
import 'package:content_automation/background/scheduler_status.dart';
import 'package:content_automation/data/models/enums.dart';
import 'package:content_automation/data/models/scheduled_upload.dart';
import 'package:content_automation/services/secure_key_value_store.dart';
import 'package:content_automation/services/settings_service.dart';
import 'package:content_automation/services/video_file_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:platform_bridge/platform_bridge.dart';

import '../helpers/in_memory_schedule_repository.dart';

void main() {
  late InMemoryScheduleRepository repository;
  late InMemoryKeyValueStore store;
  late InMemoryPlatformBridge bridge;
  late NoopBackgroundController background;

  Widget buildApp() => ContentAutomationApp(
    repository: repository,
    settingsService: SettingsService(
      store: store,
      buildDefaults: const AppSettings(),
    ),
    videoFileService: VideoFileService(),
    platformBridge: bridge,
    backgroundController: background,
  );

  setUp(() {
    repository = InMemoryScheduleRepository();
    store = InMemoryKeyValueStore();
    bridge = InMemoryPlatformBridge()
      ..ignoringBatteryOptimizations = true
      ..notificationsEnabled = true
      ..exactAlarmsAllowed = true;
    background = NoopBackgroundController();
  });

  Future<void> useTallScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<ScheduledUpload> seedUpload({
    Duration inFuture = const Duration(hours: 2),
    String title = 'Launch teaser',
  }) {
    return repository.create(
      ScheduledUpload.create(
        videoPath: '/videos/teaser.mp4',
        videoName: 'teaser.mp4',
        videoSizeBytes: 5 * 1024 * 1024,
        title: title,
        description: 'desc',
        tags: const ['launch'],
        scheduledTime: DateTime.now().add(inFuture),
        platform: UploadPlatform.both,
      ),
    );
  }

  testWidgets('home shows the empty state and the setup banner', (tester) async {
    await useTallScreen(tester);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(find.text('No uploads scheduled'), findsOneWidget);
    expect(find.text('API keys needed'), findsOneWidget);
    expect(find.textContaining('YouTube, Instagram, WhatsApp agent'), findsOneWidget);
  });

  testWidgets('add screen validates before saving', (tester) async {
    await useTallScreen(tester);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Schedule your first upload'));
    await tester.pumpAndSettle();

    expect(find.text('Schedule upload'), findsWidgets);
    expect(find.text('Select a video from this phone'), findsOneWidget);

    // Both platforms are selected by default.
    final segmented = tester.widget<SegmentedButton<UploadPlatform>>(
      find.byType(SegmentedButton<UploadPlatform>),
    );
    expect(segmented.selected, {UploadPlatform.youtube, UploadPlatform.instagram});

    // Saving without a title surfaces the validator message.
    final saveButton = find.byIcon(Icons.schedule_send);
    await tester.ensureVisible(saveButton);
    await tester.tap(saveButton);
    await tester.pumpAndSettle();
    expect(find.text('A title is required.'), findsOneWidget);

    // With a title but no video, the user is told to pick one.
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Title'),
      'My first scheduled video',
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(saveButton);
    await tester.tap(saveButton);
    await tester.pumpAndSettle();
    expect(find.text('Please select a video first.'), findsOneWidget);
  });

  testWidgets('home is calm when background execution is already allowed', (
    tester,
  ) async {
    await useTallScreen(tester);
    await seedUpload();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(find.text('Background execution restricted'), findsNothing);
    expect(find.textContaining('Scheduler: not started yet'), findsOneWidget);
    final badge = tester.widget<Badge>(
      find.descendant(
        of: find.byTooltip('Background execution'),
        matching: find.byType(Badge),
      ),
    );
    expect(badge.isLabelVisible, isFalse);
  });

  testWidgets('restricted battery settings surface a banner and a fix flow', (
    tester,
  ) async {
    await useTallScreen(tester);
    bridge.ignoringBatteryOptimizations = false;
    await seedUpload();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(find.text('Background execution restricted'), findsOneWidget);
    expect(find.textContaining('1 setting needs'), findsOneWidget);

    await tester.tap(find.text('Fix'));
    await tester.pumpAndSettle();

    // Checklist shows the missing item with its explanation.
    expect(find.text('Background execution'), findsOneWidget);
    expect(find.text('Ignore battery optimisations'), findsOneWidget);
    expect(find.text('Required'), findsOneWidget);
    expect(find.text('Allow notifications'), findsOneWidget);
    expect(find.text('Granted'), findsNWidgets(2));

    // "Allow" triggers the system request; the fake grants it.
    await tester.tap(find.text('Allow'));
    await tester.pumpAndSettle();

    expect(bridge.openedScreens, contains('battery'));
    expect(find.text('Background execution allowed'), findsOneWidget);
    expect(find.text('Granted'), findsNWidgets(3));

    // Back home the banner is gone.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Background execution restricted'), findsNothing);
  });

  testWidgets('scheduler status pushed by the service shows up on home', (
    tester,
  ) async {
    await useTallScreen(tester);
    await seedUpload(title: 'Keynote');
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    background.emit(
      SchedulerStatus(
        state: SchedulerState.uploading,
        updatedAt: DateTime.now(),
        source: 'service',
        message: 'Uploading to YouTube… 40%',
        activeUploadId: 1,
        activeTitle: 'Keynote',
        progress: 0.4,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Uploading Keynote 40%'), findsOneWidget);

    // The status screen mirrors it with the progress bar.
    await tester.tap(find.byTooltip('Background execution'));
    await tester.pumpAndSettle();
    expect(find.text('Uploading'), findsOneWidget);
    expect(find.textContaining('Keynote · 40%'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('Stop service'), findsOneWidget);
  });

  testWidgets('settings screen links to the background checklist', (
    tester,
  ) async {
    await useTallScreen(tester);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Battery optimisation, notifications and alarms'),
      findsOneWidget,
    );
    await tester.tap(find.text('Background execution'));
    await tester.pumpAndSettle();
    expect(find.text('HEALTH CHECKS'), findsOneWidget);
    expect(find.text('Start service now'), findsOneWidget);
  });

  testWidgets('settings screen saves keys into secure storage', (tester) async {
    await useTallScreen(tester);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('YouTube Data API v3'), findsOneWidget);
    expect(find.text('Instagram Graph API'), findsOneWidget);
    expect(find.text('WhatsApp Agent API'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'OAuth Client ID'),
      '1234-abc.apps.googleusercontent.com',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Saved.'), findsOneWidget);
    expect(
      await store.read(SettingsKeys.youtubeClientId),
      '1234-abc.apps.googleusercontent.com',
    );
  });

  testWidgets('settings screen rejects an invalid endpoint URL', (tester) async {
    await useTallScreen(tester);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    final endpointField = find.widgetWithText(TextFormField, 'Agent endpoint URL');
    await tester.scrollUntilVisible(
      endpointField,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(endpointField, 'not a url');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a full URL starting with https://'), findsOneWidget);
    expect(await store.read(SettingsKeys.whatsappEndpoint), isNull);
  });
}
