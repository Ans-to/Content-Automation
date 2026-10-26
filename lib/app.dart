import 'package:flutter/material.dart';
import 'package:platform_bridge/platform_bridge.dart';
import 'package:provider/provider.dart';

import 'background/background_coordinator.dart';
import 'core/constants.dart';
import 'core/theme.dart';
import 'data/repositories/schedule_repository.dart';
import 'integrations/youtube/youtube_account_service.dart';
import 'services/settings_service.dart';
import 'services/video_file_service.dart';
import 'state/background_provider.dart';
import 'state/schedule_provider.dart';
import 'state/settings_provider.dart';
import 'state/whatsapp_provider.dart';
import 'state/youtube_provider.dart';
import 'ui/home/home_screen.dart';

/// Root widget. Dependencies are injected so tests can swap in fakes.
class ContentAutomationApp extends StatelessWidget {
  const ContentAutomationApp({
    super.key,
    required this.repository,
    required this.settingsService,
    required this.videoFileService,
    required this.platformBridge,
    required this.backgroundController,
    required this.whatsapp,
    required this.youtubeAccount,
  });

  final ScheduleRepository repository;
  final SettingsService settingsService;
  final VideoFileService videoFileService;
  final PlatformBridge platformBridge;
  final BackgroundController backgroundController;

  /// WhatsApp agent tools for the Settings screen (test message, inbox).
  final WhatsAppProvider whatsapp;

  /// Google sign-in / sign-out for the Settings screen.
  final YouTubeAccountService youtubeAccount;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<VideoFileService>.value(value: videoFileService),
        Provider<ScheduleRepository>.value(value: repository),
        Provider<BackgroundController>.value(value: backgroundController),
        ChangeNotifierProvider<ScheduleProvider>(
          create: (_) => ScheduleProvider(
            repository: repository,
            videoFiles: videoFileService,
            background: backgroundController,
          )..load(),
        ),
        ChangeNotifierProvider<SettingsProvider>(
          create: (_) => SettingsProvider(service: settingsService)..load(),
        ),
        ChangeNotifierProvider<BackgroundProvider>(
          create: (_) => BackgroundProvider(
            bridge: platformBridge,
            controller: backgroundController,
          )..refresh(),
        ),
        ChangeNotifierProvider<WhatsAppProvider>.value(value: whatsapp),
        ChangeNotifierProvider<YouTubeProvider>(
          create: (context) => YouTubeProvider(
            service: youtubeAccount,
            onAccountChanged: context.read<SettingsProvider>().load,
          ),
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
