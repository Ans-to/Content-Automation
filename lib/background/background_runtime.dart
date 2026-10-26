import 'package:flutter/foundation.dart';
import 'package:platform_bridge/platform_bridge.dart';

import '../data/database/app_database.dart';
import '../data/models/enums.dart';
import '../data/repositories/schedule_repository.dart';
import '../integrations/uploaders/video_uploader.dart';
import '../integrations/whatsapp/inbox_cursor_store.dart';
import '../integrations/whatsapp/inbox_service.dart';
import '../integrations/whatsapp/whatsapp_agent.dart';
import '../integrations/whatsapp/whatsapp_client.dart';
import '../integrations/youtube/google_auth_gateway.dart';
import '../integrations/youtube/youtube_uploader.dart';
import '../services/local_notifier.dart';
import '../services/settings_service.dart';
import 'scheduler_status.dart';
import 'upload_engine.dart';
import 'wakeup_planner.dart';
import 'workmanager_gateway.dart';

/// Everything a background isolate (foreground service or WorkManager task)
/// needs, wired together. Each isolate builds its own instance; they share
/// state only through SQLite and the status file.
class BackgroundRuntime {
  BackgroundRuntime({
    this.database,
    required this.repository,
    required this.bridge,
    required this.engine,
    required this.planner,
    required this.statusStore,
    this.inbox,
  });

  /// Production wiring. Later phases swap the placeholder uploaders below
  /// for the real ones (Phases 4/5).
  static Future<BackgroundRuntime> create() async {
    final database = AppDatabase();
    final repository = SqliteScheduleRepository(database);
    const bridge = MethodChannelPlatformBridge();
    final settingsService = SettingsService();
    final whatsappClient = WhatsAppHttpClient();
    final engine = UploadEngine(
      repository: repository,
      settingsService: settingsService,
      agent: HttpWhatsAppAgent(
        settingsService: settingsService,
        client: whatsappClient,
      ),
      notifier: const BridgeLocalNotifier(bridge),
      uploaders: defaultUploaders(),
    );
    final planner = WakeupPlanner(
      repository: repository,
      bridge: bridge,
      workmanager: const WorkmanagerGatewayImpl(),
    );
    final inbox = WhatsAppInboxService(
      settingsService: settingsService,
      repository: repository,
      client: whatsappClient,
      cursorStore: FileInboxCursorStore(),
      lock: FileInboxLock(),
    );
    return BackgroundRuntime(
      database: database,
      repository: repository,
      bridge: bridge,
      engine: engine,
      planner: planner,
      statusStore: FileSchedulerStatusStore(),
      inbox: inbox,
    );
  }

  /// The real uploaders. Each background isolate gets its own Google Sign-In
  /// gateway; tokens are refreshed silently for the account stored in
  /// Settings (no Activity needed).
  static Map<UploadPlatform, VideoUploader> defaultUploaders() => {
    UploadPlatform.youtube: YouTubeUploader(auth: GoogleSignInGateway()),
    UploadPlatform.instagram: const UnavailableUploader(
      UploadPlatform.instagram,
      arrivesIn: 'Phase 5',
    ),
  };

  /// Owned database handle (null when the repository is not SQLite-backed,
  /// e.g. in tests).
  final AppDatabase? database;
  final ScheduleRepository repository;
  final PlatformBridge bridge;
  final UploadEngine engine;
  final WakeupPlanner planner;
  final SchedulerStatusStore statusStore;

  /// Answers WhatsApp "Status" messages; null when the isolate should not poll.
  final WhatsAppInboxService? inbox;

  /// Polls the inbox once, never throws (used by the service and watchdog).
  Future<InboxPollResult?> pollInbox() async {
    final service = inbox;
    if (service == null) return null;
    try {
      final result = await service.pollOnce();
      if (result.replied > 0 || result.outcome == InboxPollOutcome.failed) {
        debugPrint('WhatsApp inbox: $result');
      }
      return result;
    } catch (e) {
      debugPrint('WhatsApp inbox poll crashed: $e');
      return InboxPollResult.failed('$e');
    }
  }

  Future<void> dispose() async => database?.close();
}
