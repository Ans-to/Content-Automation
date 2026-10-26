import 'package:platform_bridge/platform_bridge.dart';

import '../core/constants.dart';
import '../data/models/scheduled_upload.dart';

/// On-device notifications about an upload's lifecycle. These complement the
/// WhatsApp messages (Phase 3) and are what you see on the phone itself.
abstract interface class LocalNotifier {
  Future<void> uploadStarting(ScheduledUpload upload);
  Future<void> uploadCompleted(ScheduledUpload upload);
  Future<void> uploadFailed(ScheduledUpload upload, String error);
}

/// Posts real notifications through the platform bridge.
class BridgeLocalNotifier implements LocalNotifier {
  const BridgeLocalNotifier(this._bridge);

  final PlatformBridge _bridge;

  static int notificationIdFor(ScheduledUpload upload) =>
      AppConstants.eventNotificationBase + (upload.id ?? 0);

  Future<void> _show(ScheduledUpload upload, String title, String body) async {
    try {
      await _bridge.showNotification(
        id: notificationIdFor(upload),
        channelId: AppConstants.eventsChannelId,
        title: title,
        body: body,
      );
    } catch (_) {
      // Notifications are best-effort; never let them break an upload.
    }
  }

  @override
  Future<void> uploadStarting(ScheduledUpload upload) => _show(
    upload,
    'Time reached',
    'Starting upload for "${upload.title}" (${upload.platform.label}).',
  );

  @override
  Future<void> uploadCompleted(ScheduledUpload upload) => _show(
    upload,
    'Upload completed',
    '"${upload.title}" — ${upload.statusSummary}',
  );

  @override
  Future<void> uploadFailed(ScheduledUpload upload, String error) => _show(
    upload,
    'Upload failed',
    '"${upload.title}": $error',
  );
}

/// Collects calls for tests.
class RecordingLocalNotifier implements LocalNotifier {
  final List<String> events = [];

  @override
  Future<void> uploadStarting(ScheduledUpload upload) async {
    events.add('starting:${upload.id}');
  }

  @override
  Future<void> uploadCompleted(ScheduledUpload upload) async {
    events.add('completed:${upload.id}');
  }

  @override
  Future<void> uploadFailed(ScheduledUpload upload, String error) async {
    events.add('failed:${upload.id}:$error');
  }
}
