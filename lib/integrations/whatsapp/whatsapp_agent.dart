import '../../data/models/scheduled_upload.dart';

/// Outbound side of the WhatsApp Agent integration.
///
/// Phase 2 ships [NoopWhatsAppAgent]; Phase 3 replaces it with the real HTTP
/// client that also answers inbound "Status" messages.
abstract interface class WhatsAppAgent {
  /// Whether credentials are present (endpoint + API key).
  bool get isConfigured;

  /// "Time reached. Starting upload for [Video Title]."
  Future<void> notifyUploadStarting(ScheduledUpload upload);

  /// Sent when any selected platform failed.
  Future<void> notifyUploadFailed(ScheduledUpload upload, String error);

  /// Sent when every selected platform finished successfully.
  Future<void> notifyUploadCompleted(ScheduledUpload upload);
}

/// Placeholder used until Phase 3: does nothing, reports "not configured".
class NoopWhatsAppAgent implements WhatsAppAgent {
  const NoopWhatsAppAgent();

  @override
  bool get isConfigured => false;

  @override
  Future<void> notifyUploadStarting(ScheduledUpload upload) async {}

  @override
  Future<void> notifyUploadFailed(ScheduledUpload upload, String error) async {}

  @override
  Future<void> notifyUploadCompleted(ScheduledUpload upload) async {}
}
