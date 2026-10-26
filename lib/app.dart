import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/constants.dart';
import 'core/theme.dart';
import 'data/repositories/schedule_repository.dart';
import 'services/settings_service.dart';
import 'services/video_file_service.dart';
import 'state/schedule_provider.dart';
import 'state/settings_provider.dart';
import 'ui/home/home_screen.dart';

/// Root widget. Dependencies are injected so tests can swap in fakes.
class ContentAutomationApp extends StatelessWidget {
  const ContentAutomationApp({
    super.key,
    required this.repository,
    required this.settingsService,
    required this.videoFileService,
  });

  final ScheduleRepository repository;
  final SettingsService settingsService;
  final VideoFileService videoFileService;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<VideoFileService>.value(value: videoFileService),
        Provider<ScheduleRepository>.value(value: repository),
        ChangeNotifierProvider<ScheduleProvider>(
          create: (_) => ScheduleProvider(
            repository: repository,
            videoFiles: videoFileService,
          )..load(),
        ),
        ChangeNotifierProvider<SettingsProvider>(
          create: (_) => SettingsProvider(service: settingsService)..load(),
        ),
      ],
      child: MaterialApp(
        title: AppConstants.appName,
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: ThemeMode.system,
        home: const HomeScreen(),
      ),
    );
  }
}
