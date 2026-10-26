import '../../data/models/scheduled_upload.dart';
import '../../services/settings_service.dart';
import 'whatsapp_client.dart';
import 'whatsapp_messages.dart';

/// Outbound side of the WhatsApp Agent integration, as seen by the
/// upload engine.
abstract interface class WhatsAppAgent {
  /// Whether an endpoint + recipient are present in Settings.
  Future<bool> isConfigured();

  /// "Time reached. Starting upload for [Video Title]."
  Future<void> notifyUploadStarting(ScheduledUpload upload);

  /// Sent when any selected platform failed.
  Future<void> notifyUploadFailed(ScheduledUpload upload, String error);

  /// Sent when every selected platform finished successfully.
  Future<void> notifyUploadCompleted(ScheduledUpload upload);
}

/// Does nothing and reports "not configured" (tests / disabled builds).
class NoopWhatsAppAgent implements WhatsAppAgent {
  const NoopWhatsAppAgent();

  @override
  Future<bool> isConfigured() async => false;

  @override
  Future<void> notifyUploadStarting(ScheduledUpload upload) async {}

  @override
  Future<void> notifyUploadFailed(ScheduledUpload upload, String error) async {}

  @override
  Future<void> notifyUploadCompleted(ScheduledUpload upload) async {}
}

/// Production agent: reads the credentials from secure storage on every call
/// (so edits in Settings apply immediately, also inside background isolates)
/// and talks to the agent over HTTP.
class HttpWhatsAppAgent implements WhatsAppAgent {
  HttpWhatsAppAgent({
    required SettingsService settingsService,
    WhatsAppHttpClient? client,
  }) : _settingsService = settingsService,
       _client = client ?? WhatsAppHttpClient();

  final SettingsService _settingsService;
  final WhatsAppHttpClient _client;

  Future<WhatsAppAgentConfig> _config() async =>
      WhatsAppAgentConfig.fromSettings(await _settingsService.load());

  @override
  Future<bool> isConfigured() async => (await _config()).isConfigured;

  @override
  Future<void> notifyUploadStarting(ScheduledUpload upload) async {
    await _client.sendText(
      await _config(),
      WhatsAppMessages.timeReached(upload),
      event: 'upload_started',
      upload: upload,
    );
  }

  @override
  Future<void> notifyUploadFailed(ScheduledUpload upload, String error) async {
    await _client.sendText(
      await _config(),
      WhatsAppMessages.uploadFailed(upload, error),
      event: 'upload_failed',
      upload: upload,
    );
  }

  @override
  Future<void> notifyUploadCompleted(ScheduledUpload upload) async {
    await _client.sendText(
      await _config(),
      WhatsAppMessages.uploadCompleted(upload),
      event: 'upload_completed',
      upload: upload,
    );
  }

  /// Used by the Settings screen's "Send test message" button. Returns the
  /// text that was sent; throws [WhatsAppAgentException] on failure.
  Future<String> sendTestMessage({DateTime? now}) async {
    final config = await _config();
    if (!config.isConfigured) {
      throw const WhatsAppAgentException(
        'Enter the agent endpoint and your WhatsApp number first.',
      );
    }
    final text = WhatsAppMessages.test(now ?? DateTime.now());
    await _client.sendText(config, text, event: 'test');
    return text;
  }
}
