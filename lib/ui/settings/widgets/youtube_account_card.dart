import 'package:flutter/material.dart';

import '../../../services/settings_service.dart';
import '../../../state/youtube_provider.dart';

/// "Sign in with Google" / signed-in account row inside the YouTube section
/// of the Settings screen.
class YouTubeAccountCard extends StatelessWidget {
  const YouTubeAccountCard({
    super.key,
    required this.provider,
    required this.saved,
    required this.clientIdUnsaved,
  });

  final YouTubeProvider provider;

  /// The *stored* settings (sign-in uses the saved client ID).
  final AppSettings saved;

  /// The client ID field differs from what is saved.
  final bool clientIdUnsaved;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final signedIn = saved.isYouTubeSignedIn;
    final hasClientId = saved.youtubeClientId.isNotEmpty;

    final String? hint;
    if (clientIdUnsaved) {
      hint = 'Save the client ID first – sign-in uses the stored value.';
    } else if (!hasClientId) {
      hint = 'Paste the Web application client ID above and save, then sign in.';
    } else if (!signedIn) {
      hint =
          'Choose the Google account that owns the channel. Uploads run in the '
          'background with this account, even when the app is closed.';
    } else {
      hint = null;
    }

    final canSignIn = hasClientId && !clientIdUnsaved && !provider.isBusy;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (signedIn)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              backgroundColor: scheme.primaryContainer,
              child: Icon(Icons.person, color: scheme.onPrimaryContainer),
            ),
            title: Text(
              saved.youtubeChannelTitle.isEmpty
                  ? 'Signed in'
                  : saved.youtubeChannelTitle,
            ),
            subtitle: Text(saved.youtubeAccountEmail),
            trailing: TextButton(
              key: const Key('youtube-sign-out'),
              onPressed: provider.isBusy ? null : provider.signOut,
              child: const Text('Sign out'),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: FilledButton.icon(
              key: const Key('youtube-sign-in'),
              onPressed: canSignIn ? provider.signIn : null,
              icon: provider.isBusy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.login),
              label: const Text('Sign in with Google'),
            ),
          ),
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              hint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        if (provider.lastError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline, size: 18, color: scheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    provider.lastError!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.error,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
