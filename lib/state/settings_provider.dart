import 'package:flutter/foundation.dart';

import '../services/settings_service.dart';

/// Holds the credentials stored in secure storage and exposes
/// "is X configured" flags to the rest of the UI.
class SettingsProvider extends ChangeNotifier {
  SettingsProvider({required SettingsService service}) : _service = service;

  final SettingsService _service;

  AppSettings _settings = const AppSettings();
  bool _isLoaded = false;
  bool _isSaving = false;
  String? _error;

  AppSettings get settings => _settings;
  bool get isLoaded => _isLoaded;
  bool get isSaving => _isSaving;
  String? get error => _error;

  bool get isYouTubeConfigured => _settings.isYouTubeConfigured;
  bool get isInstagramConfigured => _settings.isInstagramConfigured;
  bool get isWhatsAppConfigured => _settings.isWhatsAppConfigured;
  bool get isTunnelConfigured => _settings.isTunnelConfigured;

  /// `true` when at least one integration still needs its keys.
  bool get needsSetup =>
      _isLoaded &&
      !(isYouTubeConfigured && isInstagramConfigured && isWhatsAppConfigured);

  /// Short list of what is still missing, for banners.
  List<String> get missingIntegrations => [
    if (!isYouTubeConfigured) 'YouTube',
    if (!isInstagramConfigured) 'Instagram',
    if (!isWhatsAppConfigured) 'WhatsApp agent',
  ];

  Future<void> load() async {
    try {
      _settings = await _service.load();
      _error = null;
    } catch (e) {
      _error = 'Could not read secure storage: $e';
    } finally {
      _isLoaded = true;
      notifyListeners();
    }
  }

  Future<void> save(AppSettings settings) async {
    _isSaving = true;
    notifyListeners();
    try {
      await _service.save(settings);
      _settings = settings;
      _error = null;
    } catch (e) {
      _error = 'Could not save settings: $e';
      rethrow;
    } finally {
      _isSaving = false;
      notifyListeners();
    }
  }

  Future<void> clear() async {
    await _service.clear();
    _settings = const AppSettings();
    _error = null;
    notifyListeners();
  }
}
