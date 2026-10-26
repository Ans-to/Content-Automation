import 'package:flutter/material.dart';

import '../../../core/utils/formatters.dart';
import '../../../integrations/whatsapp/inbox_service.dart';
import '../../../state/whatsapp_provider.dart';

/// "Send test message" / "Check inbox now" buttons plus the last-poll
/// diagnostics, shown inside the WhatsApp section of the Settings screen.
class WhatsAppTools extends StatelessWidget {
  const WhatsAppTools({
    super.key,
    required this.provider,
    required this.configured,
    required this.unsavedChanges,
  });

  final WhatsAppProvider provider;

  /// Whether the *saved* settings contain an endpoint + number.
  final bool configured;

  /// Buttons act on saved settings, so they are disabled while the form is
  /// dirty.
  final bool unsavedChanges;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = configured && !unsavedChanges && !provider.isBusy;
    final cursor = provider.cursor;

    final String? hint;
    if (unsavedChanges) {
      hint = 'Save first – the test uses the stored settings.';
    } else if (!configured) {
      hint = 'Enter the endpoint and your number, then save.';
    } else {
      hint = null;
    }

    final lines = <_InfoLine>[
      if (provider.lastTestMessage != null)
        const _InfoLine(
          Icons.check_circle_outline,
          'Test message sent. Check WhatsApp on your phone.',
          color: Color(0xFF166534),
        ),
      if (provider.lastTestError != null)
        _InfoLine(
          Icons.error_outline,
          provider.lastTestError!,
          color: scheme.error,
        ),
      if (cursor.lastCheckedAt != null)
        _InfoLine(
          Icons.schedule_outlined,
          'Inbox last checked ${Formatters.dateTime(cursor.lastCheckedAt!)}'
          '${provider.lastPoll == null ? '' : ' · ${_describe(provider.lastPoll!)}'}',
        ),
      if (cursor.lastReplyAt != null)
        _InfoLine(
          Icons.reply_outlined,
          'Last "Status" reply ${Formatters.dateTime(cursor.lastReplyAt!)}'
          '${cursor.lastReplyPreview == null ? '' : ': ${cursor.lastReplyPreview}'}',
        ),
      if (cursor.lastError != null)
        _InfoLine(
          Icons.warning_amber_outlined,
          cursor.lastError!,
          color: scheme.error,
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: enabled ? provider.sendTest : null,
              icon: provider.isBusy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send_outlined),
              label: const Text('Send test message'),
            ),
            if (provider.hasPoller)
              OutlinedButton.icon(
                onPressed: enabled ? provider.checkInbox : null,
                icon: const Icon(Icons.inbox_outlined),
                label: const Text('Check inbox now'),
              ),
          ],
        ),
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              hint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  line.icon,
                  size: 16,
                  color: line.color ?? scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    line.text,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: line.color ?? scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  static String _describe(InboxPollResult result) => switch (result.outcome) {
    InboxPollOutcome.polled =>
      '${result.fetched} new message${result.fetched == 1 ? '' : 's'}'
          '${result.replied > 0 ? ', ${result.replied} answered' : ''}',
    InboxPollOutcome.skipped => result.detail ?? 'skipped',
    InboxPollOutcome.failed => 'failed',
  };
}

class _InfoLine {
  const _InfoLine(this.icon, this.text, {this.color});

  final IconData icon;
  final String text;
  final Color? color;
}
