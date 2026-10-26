import 'package:flutter/foundation.dart';

import '../../data/repositories/schedule_repository.dart';
import '../../services/settings_service.dart';
import 'inbound_message.dart';
import 'inbox_cursor_store.dart';
import 'status_reply_builder.dart';
import 'whatsapp_client.dart';
import 'whatsapp_messages.dart';

/// Outcome of one inbox poll (for logs and the Settings screen).
@immutable
class InboxPollResult {
  const InboxPollResult({
    required this.outcome,
    this.fetched = 0,
    this.replied = 0,
    this.detail,
  });

  const InboxPollResult.skipped(String reason)
    : this(outcome: InboxPollOutcome.skipped, detail: reason);

  const InboxPollResult.failed(String error)
    : this(outcome: InboxPollOutcome.failed, detail: error);

  final InboxPollOutcome outcome;

  /// Messages returned by the agent (before de-duplication).
  final int fetched;

  /// "Status" requests answered in this poll.
  final int replied;
  final String? detail;

  bool get ok => outcome == InboxPollOutcome.polled;

  @override
  String toString() =>
      'InboxPollResult(${outcome.name}, fetched: $fetched, '
      'replied: $replied${detail == null ? '' : ', $detail'})';
}

enum InboxPollOutcome { polled, skipped, failed }

/// Polls the agent's inbox and answers "Status" messages from the local DB.
///
/// Pure Dart: the same instance type runs in the UI isolate (while the app is
/// open), in the foreground service (while armed / uploading) and in the
/// WorkManager watchdog. A shared lock + cursor file keep them from stepping
/// on each other.
class WhatsAppInboxService {
  WhatsAppInboxService({
    required SettingsService settingsService,
    required ScheduleRepository repository,
    required WhatsAppHttpClient client,
    required InboxCursorStore cursorStore,
    required InboxLock lock,
    DateTime Function()? clock,
    this.firstRunLookback = const Duration(minutes: 10),
    this.clockSkew = const Duration(minutes: 2),
  }) : _settingsService = settingsService,
       _client = client,
       _cursorStore = cursorStore,
       _lock = lock,
       _clock = clock ?? DateTime.now,
       _replies = StatusReplyBuilder(repository, clock: clock);

  final SettingsService _settingsService;
  final WhatsAppHttpClient _client;
  final InboxCursorStore _cursorStore;
  final InboxLock _lock;
  final DateTime Function() _clock;
  final StatusReplyBuilder _replies;

  /// On the very first poll only messages this recent are considered, so an
  /// old "Status" from last week is not suddenly answered.
  final Duration firstRunLookback;

  /// Tolerance when comparing agent timestamps with the cursor.
  final Duration clockSkew;

  /// Called after each reply (for logging / UI); never awaited.
  void Function(InboundMessage request, String reply)? onReplied;

  /// `true` when polling makes sense with the current settings.
  Future<bool> isEnabled() async {
    final config = WhatsAppAgentConfig.fromSettings(
      await _settingsService.load(),
    );
    return config.isConfigured && config.supportsInbox;
  }

  Future<InboxPollResult> pollOnce() async {
    final WhatsAppAgentConfig config;
    try {
      config = WhatsAppAgentConfig.fromSettings(await _settingsService.load());
    } catch (e) {
      return InboxPollResult.failed('Could not read settings: $e');
    }
    if (!config.isConfigured) {
      return const InboxPollResult.skipped('WhatsApp agent not configured');
    }
    if (!config.supportsInbox) {
      return const InboxPollResult.skipped(
        'This agent has no inbox endpoint to poll',
      );
    }

    final result = await _lock.tryRun(() => _poll(config));
    return result ?? const InboxPollResult.skipped('Another poll is running');
  }

  Future<InboxPollResult> _poll(WhatsAppAgentConfig config) async {
    final now = _clock();
    var cursor = await _cursorStore.read();
    final since =
        cursor.lastTimestamp?.subtract(clockSkew) ??
        now.subtract(firstRunLookback);

    final List<InboundMessage> messages;
    try {
      messages = await _client.fetchInbox(config, since: since);
    } catch (e) {
      await _cursorStore.write(
        cursor.copyWith(lastCheckedAt: now, lastError: '$e'),
      );
      return InboxPollResult.failed('$e');
    }

    var replied = 0;
    String? lastError;
    var newest = cursor.lastTimestamp;
    final handled = [...cursor.handledIds];
    final recipient = config.recipientDigits;

    for (final message in messages) {
      final timestamp = message.timestamp;
      if (timestamp != null &&
          (newest == null || timestamp.isAfter(newest))) {
        newest = timestamp;
      }
      if (handled.contains(message.id)) continue;

      if (!_shouldAnswer(message, since: since, recipient: recipient)) {
        handled.add(message.id);
        continue;
      }

      try {
        final reply = await _replies.build(
          filter: WhatsAppMessages.statusFilter(message.text),
        );
        await _client.sendText(
          config,
          reply,
          event: 'status_reply',
          to: message.from ?? config.recipient,
        );
        // Only remembered once the reply went out, so a transient failure is
        // retried on the next poll.
        handled.add(message.id);
        replied++;
        cursor = cursor.copyWith(
          lastReplyAt: _clock(),
          lastReplyPreview: reply.split('\n').first,
          replyCount: cursor.replyCount + 1,
        );
        onReplied?.call(message, reply);
      } catch (e) {
        lastError = 'Reply failed: $e';
        debugPrint('WhatsApp status reply failed: $e');
      }
    }

    await _cursorStore.write(
      cursor.copyWith(
        lastTimestamp: newest ?? cursor.lastTimestamp,
        handledIds: handled,
        lastCheckedAt: now,
        lastError: lastError,
      ),
    );
    return InboxPollResult(
      outcome: InboxPollOutcome.polled,
      fetched: messages.length,
      replied: replied,
      detail: lastError,
    );
  }

  /// A status request, recent enough, from the configured number (when the
  /// agent tells us who sent it).
  bool _shouldAnswer(
    InboundMessage message, {
    required DateTime since,
    required String? recipient,
  }) {
    final timestamp = message.timestamp;
    // Too old (agents that ignore `since`).
    if (timestamp != null && timestamp.isBefore(since)) return false;
    final sender = message.fromDigits;
    if (recipient != null && sender != null && !sameNumber(sender, recipient)) {
      return false;
    }
    return WhatsAppMessages.isStatusRequest(message.text);
  }

  /// Tolerates "923001234567" vs "03001234567" vs "+92 300 1234567": leading
  /// zeros are dropped and the shorter number must be the tail of the longer.
  @visibleForTesting
  static bool sameNumber(String a, String b) {
    String strip(String digits) => digits.replaceFirst(RegExp(r'^0+'), '');
    final x = strip(InboundMessage.normalizeNumber(a) ?? '');
    final y = strip(InboundMessage.normalizeNumber(b) ?? '');
    if (x.isEmpty || y.isEmpty) return false;
    if (x == y) return true;
    final shorter = x.length < y.length ? x : y;
    final longer = identical(shorter, x) ? y : x;
    return shorter.length >= 7 && longer.endsWith(shorter);
  }
}
