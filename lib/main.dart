import 'dart:async';

import 'package:flutter/material.dart';
import 'package:platform_bridge/platform_bridge.dart';

import 'app.dart';
import 'background/background_coordinator.dart';
import 'data/database/app_database.dart';
import 'data/repositories/schedule_repository.dart';
import 'integrations/whatsapp/inbox_cursor_store.dart';
import 'integrations/whatsapp/inbox_poller.dart';
import 'integrations/whatsapp/inbox_service.dart';
import 'integrations/whatsapp/whatsapp_agent.dart';
import 'integrations/whatsapp/whatsapp_client.dart';
import 'integrations/youtube/google_auth_gateway.dart';
import 'integrations/youtube/youtube_account_service.dart';
import 'services/settings_service.dart';
import 'services/video_file_service.dart';
import 'state/whatsapp_provider.dart';

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();

  final database = AppDatabase();
  final repository = SqliteScheduleRepository(database);
  final settingsService = SettingsService();
  final videoFileService = VideoFileService();
  const platformBridge = MethodChannelPlatformBridge();
  final backgroundController = BackgroundCoordinator(
    repository: repository,
    bridge: platformBridge,
  );

  // WhatsApp agent: outbound alerts + "Status" replies while the app is open
  // (the service and the watchdog poll in the background).
  final whatsappClient = WhatsAppHttpClient();
  final whatsappAgent = HttpWhatsAppAgent(
    settingsService: settingsService,
    client: whatsappClient,
  );
  final inboxCursorStore = FileInboxCursorStore();
  final inboxPoller = ForegroundInboxPoller(
    service: WhatsAppInboxService(
      settingsService: settingsService,
      repository: repository,
      client: whatsappClient,
      cursorStore: inboxCursorStore,
      lock: FileInboxLock(),
    ),
  );
  final whatsapp = WhatsAppProvider(
    agent: whatsappAgent,
    cursorStore: inboxCursorStore,
    poller: inboxPoller,
  );

  // YouTube: interactive Google sign-in lives in the UI isolate; the
  // background isolates refresh tokens for the stored account on their own.
  final youtubeAccount = YouTubeAccountService(
    auth: GoogleSignInGateway(),
    settingsService: settingsService,
  );

  // Configure the foreground service / WorkManager once the first frame is
  // on screen so start-up stays snappy.
  binding.addPostFrameCallback((_) {
    unawaited(backgroundController.initialize());
    inboxPoller.start();
    unawaited(whatsapp.refresh());
  });

  runApp(
    ContentAutomationApp(
      repository: repository,
      settingsService: settingsService,
      videoFileService: videoFileService,
      platformBridge: platformBridge,
      backgroundController: backgroundController,
      whatsapp: whatsapp,
      youtubeAccount: youtubeAccount,
    ),
  );
}
