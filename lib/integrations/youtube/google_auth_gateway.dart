import 'package:flutter/services.dart' show PlatformException;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';

/// Scopes the app asks for: uploading plus read-only access (used to show the
/// connected channel and to check processing status after an upload).
abstract final class YouTubeScopes {
  static const String upload = 'https://www.googleapis.com/auth/youtube.upload';
  static const String readonly =
      'https://www.googleapis.com/auth/youtube.readonly';

  static const List<String> all = [upload, readonly];
}

/// The Google account the user picked in Settings.
class GoogleAccountInfo {
  const GoogleAccountInfo({
    required this.email,
    this.displayName,
    this.accessToken,
  });

  final String email;
  final String? displayName;

  /// Token granted during the interactive flow (valid for about an hour).
  final String? accessToken;
}

/// Thrown by [GoogleAuthGateway] with a message that can be shown as-is.
class GoogleAuthException implements Exception {
  const GoogleAuthException(this.message, {this.cancelled = false});

  final String message;

  /// The user dismissed the account picker / consent screen.
  final bool cancelled;

  @override
  String toString() => 'GoogleAuthException: $message';
}

/// Thin seam over `google_sign_in` so the uploader and the UI can be tested
/// without Play Services.
abstract interface class GoogleAuthGateway {
  /// Must be called (once per isolate) before anything else. [serverClientId]
  /// is the **Web application** OAuth client ID from Google Cloud Console.
  Future<void> initialize({required String serverClientId});

  /// Interactive sign-in + consent for [scopes]. UI isolate only.
  Future<GoogleAccountInfo> signIn(List<String> scopes);

  /// Access token for [email] without showing UI; `null` when the account is
  /// not signed in on this device or consent for [scopes] is missing.
  Future<String?> accessToken(List<String> scopes, {required String email});

  /// Marks [accessToken] as expired/invalid so the next [accessToken] call
  /// fetches a fresh one.
  Future<void> invalidate(String accessToken);

  Future<void> signOut();
}

/// Production implementation on top of `google_sign_in` 7.x.
///
/// * Interactive calls go through `GoogleSignIn.instance` and need an
///   Activity (the app must be in the foreground).
/// * Token refresh uses the platform interface directly with the stored
///   e-mail, which Android serves through `AuthorizationClient` without an
///   Activity — that is what lets the background service upload hours after
///   the user signed in.
class GoogleSignInGateway implements GoogleAuthGateway {
  GoogleSignInGateway();

  String? _initializedFor;
  bool _pluginInitialized = false;

  @override
  Future<void> initialize({required String serverClientId}) async {
    final id = serverClientId.trim();
    if (id.isEmpty) {
      throw const GoogleAuthException(
        'Add the Web OAuth client ID in Settings → YouTube first.',
      );
    }
    if (_initializedFor == id) return;
    if (!_pluginInitialized) {
      await GoogleSignIn.instance.initialize(serverClientId: id);
      _pluginInitialized = true;
    } else {
      // The client ID changed after the first initialisation; the platform
      // layer accepts a re-init with the new value.
      await GoogleSignInPlatform.instance.init(
        InitParameters(serverClientId: id),
      );
    }
    _initializedFor = id;
  }

  @override
  Future<GoogleAccountInfo> signIn(List<String> scopes) async {
    _ensureInitialized();
    try {
      final account = await GoogleSignIn.instance.authenticate(
        scopeHint: scopes,
      );
      final authorization = await account.authorizationClient.authorizeScopes(
        scopes,
      );
      return GoogleAccountInfo(
        email: account.email,
        displayName: account.displayName,
        accessToken: authorization.accessToken,
      );
    } on GoogleSignInException catch (e) {
      throw GoogleAuthException(
        describeSignInError(e),
        cancelled: e.code == GoogleSignInExceptionCode.canceled,
      );
    } on PlatformException catch (e) {
      throw GoogleAuthException(_describePlatformError(e));
    }
  }

  @override
  Future<String?> accessToken(
    List<String> scopes, {
    required String email,
  }) async {
    _ensureInitialized();
    try {
      final tokens = await GoogleSignInPlatform.instance
          .clientAuthorizationTokensForScopes(
            ClientAuthorizationTokensForScopesParameters(
              request: AuthorizationRequestDetails(
                scopes: scopes,
                userId: null,
                email: email,
                promptIfUnauthorized: false,
              ),
            ),
          );
      return tokens?.accessToken;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled ||
          e.code == GoogleSignInExceptionCode.uiUnavailable ||
          e.code == GoogleSignInExceptionCode.userMismatch) {
        return null;
      }
      throw GoogleAuthException(describeSignInError(e));
    } on PlatformException catch (e) {
      throw GoogleAuthException(_describePlatformError(e));
    }
  }

  @override
  Future<void> invalidate(String accessToken) async {
    _ensureInitialized();
    await GoogleSignInPlatform.instance.clearAuthorizationToken(
      ClearAuthorizationTokenParams(accessToken: accessToken),
    );
  }

  @override
  Future<void> signOut() async {
    if (_initializedFor == null) return;
    try {
      await GoogleSignIn.instance.signOut();
    } on GoogleSignInException {
      // Local sign-out is best effort; the stored e-mail is cleared anyway.
    }
  }

  void _ensureInitialized() {
    if (_initializedFor == null) {
      throw const GoogleAuthException(
        'Google Sign-In is not initialised: add the Web OAuth client ID in '
        'Settings → YouTube first.',
      );
    }
  }

  static String _describePlatformError(PlatformException e) =>
      'Google Sign-In plugin error (${e.code})'
      '${e.message == null ? '' : ': ${e.message}'}';

  /// Turns the plugin's error codes into something actionable.
  static String describeSignInError(GoogleSignInException e) {
    final detail = (e.description ?? '').trim();
    switch (e.code) {
      case GoogleSignInExceptionCode.canceled:
        return 'Sign-in was cancelled.';
      case GoogleSignInExceptionCode.interrupted:
        return 'Sign-in was interrupted. Please try again.';
      case GoogleSignInExceptionCode.clientConfigurationError:
        return 'Google rejected the OAuth client ID. Paste the client ID of '
            'type "Web application" (not the Android one) in Settings → '
            'YouTube.${detail.isEmpty ? '' : ' ($detail)'}';
      case GoogleSignInExceptionCode.providerConfigurationError:
        return 'Google Sign-In is not available on this device (Google Play '
            'services / Credential Manager missing or outdated).'
            '${detail.isEmpty ? '' : ' ($detail)'}';
      case GoogleSignInExceptionCode.uiUnavailable:
        return 'Sign-in needs the app to be open in the foreground.';
      case GoogleSignInExceptionCode.userMismatch:
        return 'A different Google account answered the request. Sign out and '
            'try again.';
      case GoogleSignInExceptionCode.unknownError:
        final lower = detail.toLowerCase();
        if (lower.contains('no credential') ||
            lower.contains('developer_error') ||
            lower.contains('10:')) {
          return 'Google could not find a credential for this app. Check that '
              'the Android OAuth client in Google Cloud uses package '
              'com.contentautomation.app and the SHA-1 of the key this APK '
              'is signed with, and that a Google account is added to the '
              'phone.${detail.isEmpty ? '' : ' ($detail)'}';
        }
        return 'Google Sign-In failed${detail.isEmpty ? '.' : ': $detail'}';
    }
  }
}

/// In-memory gateway for tests and previews.
class InMemoryGoogleAuthGateway implements GoogleAuthGateway {
  InMemoryGoogleAuthGateway({
    this.account = const GoogleAccountInfo(
      email: 'creator@example.com',
      displayName: 'Creator',
    ),
    Iterable<String> tokens = const ['token-1', 'token-2', 'token-3'],
    this.signInError,
  }) : _tokens = List.of(tokens);

  /// Account returned by [signIn]; also the only e-mail [accessToken] serves.
  GoogleAccountInfo account;

  /// When set, [signIn] throws it instead of succeeding.
  GoogleAuthException? signInError;

  final List<String> _tokens;
  final Set<String> invalidated = {};
  final List<List<String>> scopeRequests = [];

  String? initializedWith;
  bool signedIn = false;
  bool signedOut = false;
  int tokenRequests = 0;
  String? _current;

  /// `true` after a successful [signIn] (or when preset) so [accessToken]
  /// returns tokens for [account].
  bool authorized = false;

  @override
  Future<void> initialize({required String serverClientId}) async {
    if (serverClientId.trim().isEmpty) {
      throw const GoogleAuthException('Client ID missing');
    }
    initializedWith = serverClientId;
  }

  @override
  Future<GoogleAccountInfo> signIn(List<String> scopes) async {
    scopeRequests.add(List.of(scopes));
    final error = signInError;
    if (error != null) throw error;
    signedIn = true;
    authorized = true;
    return account;
  }

  @override
  Future<String?> accessToken(
    List<String> scopes, {
    required String email,
  }) async {
    tokenRequests++;
    if (!authorized || email != account.email) return null;
    final current = _current;
    if (current != null && !invalidated.contains(current)) return current;
    if (_tokens.isEmpty) return null;
    return _current = _tokens.removeAt(0);
  }

  @override
  Future<void> invalidate(String accessToken) async {
    invalidated.add(accessToken);
  }

  @override
  Future<void> signOut() async {
    signedOut = true;
    authorized = false;
    _current = null;
  }
}
