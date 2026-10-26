import 'package:content_automation/app.dart';
import 'package:content_automation/data/models/enums.dart';
import 'package:content_automation/services/secure_key_value_store.dart';
import 'package:content_automation/services/settings_service.dart';
import 'package:content_automation/services/video_file_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/in_memory_schedule_repository.dart';

void main() {
  late InMemoryScheduleRepository repository;
  late InMemoryKeyValueStore store;

  Widget buildApp() => ContentAutomationApp(
    repository: repository,
    settingsService: SettingsService(
      store: store,
      buildDefaults: const AppSettings(),
    ),
    videoFileService: VideoFileService(),
  );

  setUp(() {
    repository = InMemoryScheduleRepository();
    store = InMemoryKeyValueStore();
  });

  Future<void> useTallScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
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
