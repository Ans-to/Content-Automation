import 'package:flutter/foundation.dart';

import '../core/env.dart';
import 'secure_key_value_store.dart';

/// Keys under which each credential is stored in secure storage.
abstract final class SettingsKeys {
  static const String youtubeClientId = 'youtube_client_id';
  static const String youtubeApiKey = 'youtube_api_key';

  static const String instagramAppId = 'instagram_app_id';
  static const String instagramAccessToken = 'instagram_access_token';
  static const String instagramBusinessAccountId =
      'instagram_business_account_id';

  static const String whatsappEndpoint = 'whatsapp_agent_endpoint';
  static const String whatsappApiKey = 'whatsapp_agent_api_key';
  static const String whatsappRecipient = 'whatsapp_recipient_number';

  static const String ngrokAuthToken = 'ngrok_authtoken';

  static const List<String> all = [
    youtubeClientId,
    youtubeApiKey,
    instagramAppId,
    instagramAccessToken,
    instagramBusinessAccountId,
    whatsappEndpoint,
    whatsappApiKey,
    whatsappRecipient,
    ngrokAuthToken,
  ];
}

/// All user-provided credentials. Empty string == not configured.
@immutable
class AppSettings {
  const AppSettings({
    this.youtubeClientId = '',
    this.youtubeApiKey = '',
    this.instagramAppId = '',
    this.instagramAccessToken = '',
    this.instagramBusinessAccountId = '',
    this.whatsappEndpoint = '',
    this.whatsappApiKey = '',
    this.whatsappRecipient = '',
    this.ngrokAuthToken = '',
  });

  /// Values baked in at build time via `--dart-define-from-file=.env`
  /// (placeholders are mapped to empty strings).
  factory AppSettings.fromEnv() => AppSettings(
    youtubeClientId: Env.valueOrNull(Env.youtubeClientId) ?? '',
    youtubeApiKey: Env.valueOrNull(Env.youtubeApiKey) ?? '',
    instagramAppId: Env.valueOrNull(Env.instagramAppId) ?? '',
    instagramAccessToken: Env.valueOrNull(Env.instagramAccessToken) ?? '',
    instagramBusinessAccountId:
        Env.valueOrNull(Env.instagramBusinessAccountId) ?? '',
    whatsappEndpoint: Env.valueOrNull(Env.whatsappAgentEndpoint) ?? '',
    whatsappApiKey: Env.valueOrNull(Env.whatsappAgentApiKey) ?? '',
    whatsappRecipient: Env.valueOrNull(Env.whatsappRecipientNumber) ?? '',
    ngrokAuthToken: Env.valueOrNull(Env.ngrokAuthToken) ?? '',
  );

  factory AppSettings.fromMap(Map<String, String> map) => AppSettings(
    youtubeClientId: map[SettingsKeys.youtubeClientId] ?? '',
    youtubeApiKey: map[SettingsKeys.youtubeApiKey] ?? '',
    instagramAppId: map[SettingsKeys.instagramAppId] ?? '',
    instagramAccessToken: map[SettingsKeys.instagramAccessToken] ?? '',
    instagramBusinessAccountId:
        map[SettingsKeys.instagramBusinessAccountId] ?? '',
    whatsappEndpoint: map[SettingsKeys.whatsappEndpoint] ?? '',
    whatsappApiKey: map[SettingsKeys.whatsappApiKey] ?? '',
    whatsappRecipient: map[SettingsKeys.whatsappRecipient] ?? '',
    ngrokAuthToken: map[SettingsKeys.ngrokAuthToken] ?? '',
  );

  // YouTube Data API v3
  final String youtubeClientId;
  final String youtubeApiKey;

  // Instagram Graph API
  final String instagramAppId;
  final String instagramAccessToken;
  final String instagramBusinessAccountId;

  // WhatsApp Agent API
  final String whatsappEndpoint;
  final String whatsappApiKey;
  final String whatsappRecipient;

  // Tunnel (Phase 5)
  final String ngrokAuthToken;

  /// The OAuth client ID is what the YouTube uploader needs; the API key is
  /// optional (only used for unauthenticated reads).
  bool get isYouTubeConfigured => youtubeClientId.isNotEmpty;

  bool get isInstagramConfigured =>
      instagramAccessToken.isNotEmpty && instagramBusinessAccountId.isNotEmpty;

  bool get isWhatsAppConfigured =>
      whatsappEndpoint.isNotEmpty && whatsappApiKey.isNotEmpty;

  bool get isTunnelConfigured => ngrokAuthToken.isNotEmpty;

  bool get isEmpty => toMap().values.every((v) => v.isEmpty);

  Map<String, String> toMap() => {
    SettingsKeys.youtubeClientId: youtubeClientId,
    SettingsKeys.youtubeApiKey: youtubeApiKey,
    SettingsKeys.instagramAppId: instagramAppId,
    SettingsKeys.instagramAccessToken: instagramAccessToken,
    SettingsKeys.instagramBusinessAccountId: instagramBusinessAccountId,
    SettingsKeys.whatsappEndpoint: whatsappEndpoint,
    SettingsKeys.whatsappApiKey: whatsappApiKey,
    SettingsKeys.whatsappRecipient: whatsappRecipient,
    SettingsKeys.ngrokAuthToken: ngrokAuthToken,
  };

  /// Returns a copy where every *empty* field is filled from [defaults].
  /// Existing values always win, so user edits are never overwritten.
  AppSettings fillMissingFrom(AppSettings defaults) {
    final current = toMap();
    final fallback = defaults.toMap();
    final merged = <String, String>{
      for (final key in SettingsKeys.all)
        key: (current[key] ?? '').isNotEmpty
            ? current[key]!
            : (fallback[key] ?? ''),
    };
    return AppSettings.fromMap(merged);
  }

  AppSettings copyWith({
    String? youtubeClientId,
    String? youtubeApiKey,
    String? instagramAppId,
    String? instagramAccessToken,
    String? instagramBusinessAccountId,
    String? whatsappEndpoint,
    String? whatsappApiKey,
    String? whatsappRecipient,
    String? ngrokAuthToken,
  }) => AppSettings(
    youtubeClientId: youtubeClientId ?? this.youtubeClientId,
    youtubeApiKey: youtubeApiKey ?? this.youtubeApiKey,
    instagramAppId: instagramAppId ?? this.instagramAppId,
    instagramAccessToken: instagramAccessToken ?? this.instagramAccessToken,
    instagramBusinessAccountId:
        instagramBusinessAccountId ?? this.instagramBusinessAccountId,
    whatsappEndpoint: whatsappEndpoint ?? this.whatsappEndpoint,
    whatsappApiKey: whatsappApiKey ?? this.whatsappApiKey,
    whatsappRecipient: whatsappRecipient ?? this.whatsappRecipient,
    ngrokAuthToken: ngrokAuthToken ?? this.ngrokAuthToken,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppSettings && mapEquals(other.toMap(), toMap());

  @override
  int get hashCode => Object.hashAll(toMap().values);

  @override
  String toString() => 'AppSettings(youtube: $isYouTubeConfigured, '
      'instagram: $isInstagramConfigured, whatsapp: $isWhatsAppConfigured, '
      'tunnel: $isTunnelConfigured)';
}

/// Loads and saves [AppSettings] in the device's encrypted storage.
class SettingsService {
  SettingsService({SecureKeyValueStore? store, AppSettings? buildDefaults})
    : _store = store ?? FlutterSecureKeyValueStore(),
      _buildDefaults = buildDefaults ?? AppSettings.fromEnv();

  final SecureKeyValueStore _store;
  final AppSettings _buildDefaults;

  /// Reads the stored settings. Any field that is still empty is seeded from
  /// the build-time `.env` defaults (placeholders are ignored) and persisted,
  /// so a developer build can ship pre-filled while the phone stays the
  /// source of truth.
  Future<AppSettings> load() async {
    final stored = AppSettings.fromMap(await _store.readAll());
    final seeded = stored.fillMissingFrom(_buildDefaults);
    if (seeded != stored) {
      await save(seeded);
    }
    return seeded;
  }

  /// Persists every field. Empty fields are removed from storage.
  Future<void> save(AppSettings settings) async {
    for (final entry in settings.toMap().entries) {
      await _store.write(entry.key, entry.value.trim());
    }
  }

  /// Removes every stored credential.
  Future<void> clear() async {
    for (final key in SettingsKeys.all) {
      await _store.delete(key);
    }
  }
}
