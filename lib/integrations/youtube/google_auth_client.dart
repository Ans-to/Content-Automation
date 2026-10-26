import 'package:http/http.dart' as http;

import 'google_auth_gateway.dart';

/// Supplies OAuth access tokens, refreshing them on demand.
abstract interface class AccessTokenSource {
  /// A token that is believed to be valid. With [forceRefresh] the current
  /// token is discarded first (used after a 401).
  Future<String> token({bool forceRefresh = false});
}

/// Thrown when no token can be obtained; the message is user-facing.
class MissingAuthorizationException implements Exception {
  const MissingAuthorizationException(this.message);

  final String message;

  @override
  String toString() => 'MissingAuthorizationException: $message';
}

/// [AccessTokenSource] backed by [GoogleAuthGateway] for the account the user
/// signed in with. Tokens are cached for [ttl] (Google issues them for one
/// hour) and dropped on [forceRefresh].
class GatewayTokenSource implements AccessTokenSource {
  GatewayTokenSource({
    required GoogleAuthGateway gateway,
    required this.email,
    this.scopes = YouTubeScopes.all,
    this.ttl = const Duration(minutes: 40),
    DateTime Function()? clock,
  }) : _gateway = gateway,
       _clock = clock ?? DateTime.now;

  final GoogleAuthGateway _gateway;
  final String email;
  final List<String> scopes;
  final Duration ttl;
  final DateTime Function() _clock;

  String? _token;
  DateTime? _fetchedAt;

  @override
  Future<String> token({bool forceRefresh = false}) async {
    final current = _token;
    final fetchedAt = _fetchedAt;
    if (!forceRefresh &&
        current != null &&
        fetchedAt != null &&
        _clock().difference(fetchedAt) < ttl) {
      return current;
    }
    if (current != null && forceRefresh) {
      try {
        await _gateway.invalidate(current);
      } catch (_) {
        // Best effort; a fresh request follows anyway.
      }
    }
    _token = null;
    final fresh = await _gateway.accessToken(scopes, email: email);
    if (fresh == null || fresh.isEmpty) {
      throw const MissingAuthorizationException(
        'YouTube authorization is missing or expired for this device. Open '
        'the app → Settings → YouTube and sign in with Google again.',
      );
    }
    _token = fresh;
    _fetchedAt = _clock();
    return fresh;
  }
}

/// `http.Client` that adds `Authorization: Bearer …` and retries once with a
/// refreshed token when Google answers 401. Only replayable requests (plain
/// [http.Request]) are retried; streamed uploads handle 401 themselves.
class GoogleAuthClient extends http.BaseClient {
  GoogleAuthClient(this._inner, this._tokens);

  final http.Client _inner;
  final AccessTokenSource _tokens;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    request.headers['Authorization'] = 'Bearer ${await _tokens.token()}';
    final response = await _inner.send(request);
    if (response.statusCode != 401 || request is! http.Request) {
      return response;
    }
    // Drain the failed body so the connection can be reused.
    await response.stream.drain<void>();
    final retry = http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..bodyBytes = request.bodyBytes
      ..followRedirects = request.followRedirects
      ..maxRedirects = request.maxRedirects
      ..persistentConnection = request.persistentConnection;
    retry.headers['Authorization'] =
        'Bearer ${await _tokens.token(forceRefresh: true)}';
    return _inner.send(retry);
  }

  @override
  void close() => _inner.close();
}
