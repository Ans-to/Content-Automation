import 'package:flutter/foundation.dart';

import '../integrations/youtube/google_auth_gateway.dart';
import '../integrations/youtube/youtube_account_service.dart';

/// Settings-screen state for the YouTube account (sign in / sign out).
class YouTubeProvider extends ChangeNotifier {
  YouTubeProvider({
    required YouTubeAccountService service,
    Future<void> Function()? onAccountChanged,
  }) : _service = service,
       _onAccountChanged = onAccountChanged;

  final YouTubeAccountService _service;

  /// Invoked after the stored account changed (reloads [SettingsProvider]).
  final Future<void> Function()? _onAccountChanged;

  bool _busy = false;
  String? _lastError;
  YouTubeAccount? _lastSignedIn;

  bool get isBusy => _busy;
  String? get lastError => _lastError;

  /// Account returned by the most recent successful sign-in this session.
  YouTubeAccount? get lastSignedIn => _lastSignedIn;

  /// Opens the Google account picker + consent screen. Returns `true` when an
  /// account was stored.
  Future<bool> signIn() async {
    _busy = true;
    _lastError = null;
    notifyListeners();
    try {
      _lastSignedIn = await _service.signIn();
      await _onAccountChanged?.call();
      return true;
    } on GoogleAuthException catch (e) {
      _lastError = e.cancelled ? null : e.message;
      return false;
    } catch (e) {
      _lastError = 'Sign-in failed: $e';
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> signOut() async {
    _busy = true;
    _lastError = null;
    notifyListeners();
    try {
      await _service.signOut();
      _lastSignedIn = null;
      await _onAccountChanged?.call();
    } catch (e) {
      _lastError = 'Sign-out failed: $e';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  void clearError() {
    if (_lastError == null) return;
    _lastError = null;
    notifyListeners();
  }
}
