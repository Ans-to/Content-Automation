import 'package:googleapis/youtube/v3.dart' as yt;
import 'package:http/http.dart' as http;

import '../../services/settings_service.dart';
import 'google_auth_client.dart';
import 'google_auth_gateway.dart';

/// Result of an interactive sign-in.
class YouTubeAccount {
  const YouTubeAccount({required this.email, this.channelTitle = ''});

  final String email;
  final String channelTitle;
}

/// Settings-screen side of the YouTube integration: sign in with Google,
/// remember the account for the background uploader, sign out.
class YouTubeAccountService {
  YouTubeAccountService({
    required GoogleAuthGateway auth,
    required SettingsService settingsService,
    http.Client? client,
    String apiRootUrl = 'https://youtube.googleapis.com/',
  }) : _auth = auth,
       _settingsService = settingsService,
       _client = client ?? http.Client(),
       _apiRootUrl = apiRootUrl;

  final GoogleAuthGateway _auth;
  final SettingsService _settingsService;
  final http.Client _client;
  final String _apiRootUrl;

  /// Runs the Google account picker + consent screen, looks up the channel
  /// name and stores both in secure settings. Throws [GoogleAuthException]
  /// with a user-facing message on failure.
  Future<YouTubeAccount> signIn() async {
    final settings = await _settingsService.load();
    await _auth.initialize(serverClientId: settings.youtubeClientId);
    final account = await _auth.signIn(YouTubeScopes.all);
    if (account.email.trim().isEmpty) {
      throw const GoogleAuthException(
        'Google did not return the account e-mail; the app needs it to '
        'refresh tokens in the background. Try another account.',
      );
    }

    final channelTitle = await _lookupChannelTitle(account);
    await _settingsService.save(
      settings.copyWith(
        youtubeAccountEmail: account.email.trim(),
        youtubeChannelTitle: channelTitle,
      ),
    );
    return YouTubeAccount(email: account.email.trim(), channelTitle: channelTitle);
  }

  /// Forgets the account locally (Google keeps the consent until revoked at
  /// myaccount.google.com/permissions).
  Future<void> signOut() async {
    final settings = await _settingsService.load();
    try {
      if (settings.youtubeClientId.isNotEmpty) {
        await _auth.initialize(serverClientId: settings.youtubeClientId);
      }
      await _auth.signOut();
    } on GoogleAuthException {
      // Nothing to undo on the Google side; still clear local state.
    }
    await _settingsService.save(
      settings.copyWith(youtubeAccountEmail: '', youtubeChannelTitle: ''),
    );
  }

  Future<String> _lookupChannelTitle(GoogleAccountInfo account) async {
    try {
      final tokens = _InteractiveTokenSource(
        initial: account.accessToken,
        fallback: GatewayTokenSource(gateway: _auth, email: account.email),
      );
      final api = yt.YouTubeApi(
        GoogleAuthClient(_client, tokens),
        rootUrl: _apiRootUrl,
      );
      final response = await api.channels
          .list(['snippet'], mine: true)
          .timeout(const Duration(seconds: 20));
      return response.items?.firstOrNull?.snippet?.title?.trim() ?? '';
    } catch (_) {
      // The channel name is cosmetic; uploads only need the e-mail.
      return '';
    }
  }
}

/// Uses the token handed out by the sign-in flow first, then the gateway.
class _InteractiveTokenSource implements AccessTokenSource {
  _InteractiveTokenSource({required String? initial, required this.fallback})
    : _initial = initial;

  String? _initial;
  final AccessTokenSource fallback;

  @override
  Future<String> token({bool forceRefresh = false}) async {
    final initial = _initial;
    if (initial != null && initial.isNotEmpty && !forceRefresh) return initial;
    _initial = null;
    return fallback.token(forceRefresh: forceRefresh);
  }
}
