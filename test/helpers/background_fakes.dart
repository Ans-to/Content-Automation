import 'dart:async';

import 'package:content_automation/background/background_runtime.dart';
import 'package:content_automation/background/scheduler_status.dart';
import 'package:content_automation/background/upload_engine.dart';
import 'package:content_automation/background/wakeup_planner.dart';
import 'package:content_automation/background/workmanager_gateway.dart';
import 'package:content_automation/data/models/enums.dart';
import 'package:content_automation/data/models/scheduled_upload.dart';
import 'package:content_automation/integrations/uploaders/video_uploader.dart';
import 'package:content_automation/integrations/whatsapp/inbox_service.dart';
import 'package:content_automation/integrations/whatsapp/whatsapp_agent.dart';
import 'package:content_automation/services/local_notifier.dart';
import 'package:content_automation/services/secure_key_value_store.dart';
import 'package:content_automation/services/settings_service.dart';
import 'package:platform_bridge/platform_bridge.dart';

import 'in_memory_schedule_repository.dart';

/// Deterministic, settable clock for the engine/planner tests.
class FakeClock {
  FakeClock(this.now);

  DateTime now;

  DateTime call() => now;

  void advance(Duration by) => now = now.add(by);
}

/// Uploader whose result is scripted per test.
class FakeUploader implements VideoUploader {
  FakeUploader(
    this.platform, {
    this.remoteId,
    this.error,
    this.progressSteps = const [0.5, 1.0],
    this.throwError,
  });

  @override
  final UploadPlatform platform;
  final String? remoteId;
  final String? error;
  final Object? throwError;
  final List<double> progressSteps;

  final List<ScheduledUpload> calls = [];
  AppSettings? lastSettings;

  @override
  Future<UploadOutcome> upload(
    ScheduledUpload upload, {
    required AppSettings settings,
    required UploadProgressCallback onProgress,
    required UploadLogger log,
  }) async {
    calls.add(upload);
    lastSettings = settings;
    await log('${platform.label}: fake upload started');
    for (final step in progressSteps) {
      onProgress(step);
    }
    if (throwError != null) throw throwError!;
    if (error != null) return UploadOutcome.failure(error!);
    return UploadOutcome.success(remoteId: remoteId);
  }
}

/// Records the WhatsApp messages the engine would send.
class RecordingWhatsAppAgent implements WhatsAppAgent {
  RecordingWhatsAppAgent({this.configured = true, this.failWith});

  final bool configured;

  @override
  Future<bool> isConfigured() async => configured;

  /// When set, every call throws this error.
  final Object? failWith;

  final List<String> messages = [];

  @override
  Future<void> notifyUploadStarting(ScheduledUpload upload) async {
    _maybeFail();
    messages.add('Time reached. Starting upload for ${upload.title}.');
  }

  @override
  Future<void> notifyUploadFailed(ScheduledUpload upload, String error) async {
    _maybeFail();
    messages.add('Upload failed for ${upload.title}: $error');
  }

  @override
  Future<void> notifyUploadCompleted(ScheduledUpload upload) async {
    _maybeFail();
    messages.add('Upload completed for ${upload.title}.');
  }

  void _maybeFail() {
    if (failWith != null) throw failWith!;
  }
}

/// Builds a fully faked [UploadEngine] + [BackgroundRuntime].
class EngineHarness {
  EngineHarness({
    DateTime? now,
    Map<UploadPlatform, VideoUploader>? uploaders,
    RecordingWhatsAppAgent? agent,
    bool fileExistsInitially = true,
    Duration staleTimeout = const Duration(minutes: 20),
    WhatsAppInboxService? inbox,
  }) : clock = FakeClock(now ?? DateTime(2026, 10, 26, 18, 0)),
       agent = agent ?? RecordingWhatsAppAgent(),
       fileExists = fileExistsInitially {
    youtube = (uploaders?[UploadPlatform.youtube] as FakeUploader?) ??
        FakeUploader(UploadPlatform.youtube, remoteId: 'yt123');
    instagram = (uploaders?[UploadPlatform.instagram] as FakeUploader?) ??
        FakeUploader(UploadPlatform.instagram, remoteId: 'ig456');
    engine = UploadEngine(
      repository: repository,
      settingsService: SettingsService(
        store: InMemoryKeyValueStore(),
        buildDefaults: const AppSettings(),
      ),
      agent: this.agent,
      notifier: notifier,
      uploaders: {
        UploadPlatform.youtube: youtube,
        UploadPlatform.instagram: instagram,
      },
      clock: clock.call,
      staleTimeout: staleTimeout,
      fileExists: (_) => fileExists,
    );
    planner = WakeupPlanner(
      repository: repository,
      bridge: bridge,
      workmanager: workmanager,
      clock: clock.call,
    );
    runtime = BackgroundRuntime(
      repository: repository,
      bridge: bridge,
      engine: engine,
      planner: planner,
      statusStore: statusStore,
      inbox: inbox,
    );
  }

  final FakeClock clock;
  final InMemoryScheduleRepository repository = InMemoryScheduleRepository();
  final RecordingLocalNotifier notifier = RecordingLocalNotifier();
  final RecordingWhatsAppAgent agent;
  final InMemoryPlatformBridge bridge = InMemoryPlatformBridge();
  final RecordingWorkmanagerGateway workmanager = RecordingWorkmanagerGateway();
  final InMemorySchedulerStatusStore statusStore = InMemorySchedulerStatusStore();
  final List<EngineActivity> activities = [];

  /// What the engine's file check reports (flip to simulate a deleted video).
  bool fileExists;

  late final FakeUploader youtube;
  late final FakeUploader instagram;
  late final UploadEngine engine;
  late final WakeupPlanner planner;
  late final BackgroundRuntime runtime;

  /// Inserts a scheduled upload due at [clock.now] + [inFuture].
  Future<ScheduledUpload> addUpload({
    Duration inFuture = Duration.zero,
    UploadPlatform platform = UploadPlatform.both,
    String title = 'Launch teaser',
  }) {
    return repository.create(
      ScheduledUpload.create(
        videoPath: '/videos/$title.mp4',
        videoName: '$title.mp4',
        videoSizeBytes: 1024,
        title: title,
        description: 'desc',
        tags: const ['a'],
        scheduledTime: clock.now.add(inFuture),
        platform: platform,
      ),
    );
  }

  void captureActivity() {
    engine.onActivity = activities.add;
  }

  Future<List<String>> eventMessages(int id) async =>
      (await repository.getEvents(id)).reversed.map((e) => e.message).toList();
}

/// Bridge that reports no alarm facility at all (some locked-down ROMs).
class NoAlarmPlatformBridge extends InMemoryPlatformBridge {
  @override
  Future<WakeupKind> scheduleWakeup(DateTime at) async {
    scheduledWakeup = at;
    return WakeupKind.unavailable;
  }
}

/// Collects everything emitted on a stream for assertions.
class StreamRecorder<T> {
  StreamRecorder(Stream<T> stream) {
    _subscription = stream.listen(items.add);
  }

  final List<T> items = [];
  late final StreamSubscription<T> _subscription;

  Future<void> dispose() => _subscription.cancel();
}

SchedulerStatus statusOf(SchedulerState state, {String source = 'service'}) =>
    SchedulerStatus(state: state, updatedAt: DateTime(2026), source: source);
