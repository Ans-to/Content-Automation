import 'package:platform_bridge/platform_bridge.dart';

import '../data/database/app_database.dart';
import '../data/models/enums.dart';
import '../data/repositories/schedule_repository.dart';
import '../integrations/uploaders/video_uploader.dart';
import '../integrations/whatsapp/whatsapp_agent.dart';
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
  });

  /// Production wiring. Later phases swap the placeholders below for the real
  /// WhatsApp agent (Phase 3) and uploaders (Phases 4/5).
  static Future<BackgroundRuntime> create() async {
    final database = AppDatabase();
    final repository = SqliteScheduleRepository(database);
    const bridge = MethodChannelPlatformBridge();
    final engine = UploadEngine(
      repository: repository,
      settingsService: SettingsService(),
      agent: defaultAgent(),
      notifier: const BridgeLocalNotifier(bridge),
      uploaders: defaultUploaders(),
    );
    final planner = WakeupPlanner(
      repository: repository,
      bridge: bridge,
      workmanager: const WorkmanagerGatewayImpl(),
    );
    return BackgroundRuntime(
      database: database,
      repository: repository,
      bridge: bridge,
      engine: engine,
      planner: planner,
      statusStore: FileSchedulerStatusStore(),
    );
  }

  static WhatsAppAgent defaultAgent() => const NoopWhatsAppAgent();

  static Map<UploadPlatform, VideoUploader> defaultUploaders() => const {
    UploadPlatform.youtube: UnavailableUploader(
      UploadPlatform.youtube,
      arrivesIn: 'Phase 4',
    ),
    UploadPlatform.instagram: UnavailableUploader(
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

  Future<void> dispose() async => database?.close();
}
