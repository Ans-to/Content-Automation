/// Build-time defaults for API credentials.
///
/// Every value is a `String.fromEnvironment` constant so it can be supplied at
/// compile time with `--dart-define-from-file=.env` (see `.env.example`).
/// When nothing is supplied the `YOUR_...` placeholder is baked in instead and
/// the app treats the setting as *not configured*.
///
/// IMPORTANT: these are only **seeds**. The source of truth at runtime is the
/// phone's encrypted secure storage (see `SettingsService`), which the user
/// fills in from the Settings screen. Nothing here is required for the app to
/// build or run.
abstract final class Env {
  // --- YouTube Data API v3 ---------------------------------------------------
  static const String youtubeClientId = String.fromEnvironment(
    'YOUTUBE_CLIENT_ID',
    defaultValue: 'YOUR_YOUTUBE_CLIENT_ID',
  );
  static const String youtubeApiKey = String.fromEnvironment(
    'YOUTUBE_API_KEY',
    defaultValue: 'YOUR_YOUTUBE_API_KEY',
  );

  // --- Instagram Graph API ---------------------------------------------------
  static const String instagramAppId = String.fromEnvironment(
    'INSTAGRAM_APP_ID',
    defaultValue: 'YOUR_INSTAGRAM_APP_ID',
  );
  static const String instagramAccessToken = String.fromEnvironment(
    'INSTAGRAM_ACCESS_TOKEN',
    defaultValue: 'YOUR_INSTAGRAM_ACCESS_TOKEN',
  );
  static const String instagramBusinessAccountId = String.fromEnvironment(
    'INSTAGRAM_BUSINESS_ACCOUNT_ID',
    defaultValue: 'YOUR_INSTAGRAM_BUSINESS_ACCOUNT_ID',
  );

  // --- WhatsApp Agent API ----------------------------------------------------
  static const String whatsappAgentEndpoint = String.fromEnvironment(
    'WHATSAPP_AGENT_ENDPOINT',
    defaultValue: 'YOUR_WHATSAPP_AGENT_ENDPOINT',
  );
  static const String whatsappAgentApiKey = String.fromEnvironment(
    'WHATSAPP_AGENT_API_KEY',
    defaultValue: 'YOUR_WHATSAPP_AGENT_API_KEY',
  );
  static const String whatsappRecipientNumber = String.fromEnvironment(
    'WHATSAPP_RECIPIENT_NUMBER',
    defaultValue: 'YOUR_WHATSAPP_RECIPIENT_NUMBER',
  );

  // --- Tunnel (Instagram device-first bridge, Phase 5) -----------------------
  static const String ngrokAuthToken = String.fromEnvironment(
    'NGROK_AUTHTOKEN',
    defaultValue: 'YOUR_NGROK_AUTHTOKEN',
  );
  static const String cloudflaredTunnelToken = String.fromEnvironment(
    'CLOUDFLARED_TUNNEL_TOKEN',
    defaultValue: 'YOUR_CLOUDFLARED_TUNNEL_TOKEN',
  );

  /// `true` when [value] is empty or still one of the `YOUR_...` placeholders.
  static bool isPlaceholder(String? value) {
    if (value == null) return true;
    final trimmed = value.trim();
    return trimmed.isEmpty || trimmed.startsWith('YOUR_');
  }

  /// Returns the trimmed value, or `null` when it is only a placeholder.
  static String? valueOrNull(String value) =>
      isPlaceholder(value) ? null : value.trim();
}
