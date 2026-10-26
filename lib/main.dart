import 'dart:async';

import 'package:flutter/material.dart';
import 'package:platform_bridge/platform_bridge.dart';

import 'app.dart';
import 'background/background_coordinator.dart';
import 'data/database/app_database.dart';
import 'data/repositories/schedule_repository.dart';
import 'services/settings_service.dart';
import 'services/video_file_service.dart';

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

  // Configure the foreground service / WorkManager once the first frame is
  // on screen so start-up stays snappy.
  binding.addPostFrameCallback((_) {
    unawaited(backgroundController.initialize());
  });

  runApp(
    ContentAutomationApp(
      repository: repository,
      settingsService: settingsService,
      videoFileService: videoFileService,
      platformBridge: platformBridge,
      backgroundController: backgroundController,
    ),
  );
}
