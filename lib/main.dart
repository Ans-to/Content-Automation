import 'package:flutter/material.dart';

import 'app.dart';
import 'data/database/app_database.dart';
import 'data/repositories/schedule_repository.dart';
import 'services/settings_service.dart';
import 'services/video_file_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final database = AppDatabase();
  final repository = SqliteScheduleRepository(database);
  final settingsService = SettingsService();
  final videoFileService = VideoFileService();

  runApp(
    ContentAutomationApp(
      repository: repository,
      settingsService: settingsService,
      videoFileService: videoFileService,
    ),
  );
}
