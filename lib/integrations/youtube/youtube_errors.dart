import 'dart:convert';

/// Broad classes of failure; the engine only needs [isTransient] and the
/// message, the uploader uses [YouTubeErrorKind.sessionExpired] to restart.
enum YouTubeErrorKind {
  /// 401 / missing consent — the user has to sign in again.
  authorization,

  /// Daily API quota or channel upload limit reached.
  quota,

  /// YouTube rejected title / description / tags.
  invalidMetadata,

  /// The resumable session URI is no longer valid (404 / 410).
  sessionExpired,

  /// Connection problems; safe to retry.
  network,

  /// 5xx from Google; safe to retry.
  server,

  /// Anything else (4xx with an unknown reason).
  other,
}

/// Exception with a user-facing [message].
class YouTubeUploadException implements Exception {
  const YouTubeUploadException(
    this.kind,
    this.message, {
    this.statusCode,
    this.reason,
  });

  /// Builds an exception from a Google API error response body such as
  /// `{"error": {"code": 403, "message": "…", "errors": [{"reason": "…"}]}}`.
  factory YouTubeUploadException.fromResponse(int statusCode, String body) {
    final parsed = _parseGoogleError(body);
    final reason = parsed.reason;
    final apiMessage = parsed.message;

    String withDetail(String text) =>
        apiMessage == null || apiMessage.isEmpty ? text : '$text ($apiMessage)';

    switch (reason) {
      case 'quotaExceeded':
      case 'dailyLimitExceeded':
      case 'rateLimitExceeded':
      case 'userRateLimitExceeded':
        return YouTubeUploadException(
          YouTubeErrorKind.quota,
          'YouTube Data API quota exceeded. Each upload costs about 1,600 of '
          'the default 10,000 daily units; the quota resets at midnight '
          'Pacific Time.',
          statusCode: statusCode,
          reason: reason,
        );
      case 'uploadLimitExceeded':
        return YouTubeUploadException(
          YouTubeErrorKind.quota,
          'This YouTube channel has reached its upload limit for today.',
          statusCode: statusCode,
          reason: reason,
        );
      case 'youtubeSignupRequired':
        return YouTubeUploadException(
          YouTubeErrorKind.authorization,
          'The signed-in Google account has no YouTube channel. Create one at '
          'youtube.com, then try again.',
          statusCode: statusCode,
          reason: reason,
        );
      case 'insufficientPermissions':
      case 'forbidden':
      case 'authError':
        return YouTubeUploadException(
          YouTubeErrorKind.authorization,
          withDetail(
            'YouTube refused the request with the current permissions. Open '
            'Settings → YouTube, sign out and sign in again, allowing '
            '"Manage your YouTube videos".',
          ),
          statusCode: statusCode,
          reason: reason,
        );
      case 'invalidTitle':
      case 'invalidDescription':
      case 'invalidTags':
      case 'invalidCategoryId':
      case 'invalidVideoMetadata':
      case 'invalidPublishAt':
        return YouTubeUploadException(
          YouTubeErrorKind.invalidMetadata,
          withDetail('YouTube rejected the video details ($reason).'),
          statusCode: statusCode,
          reason: reason,
        );
    }

    if (statusCode == 401) {
      return YouTubeUploadException(
        YouTubeErrorKind.authorization,
        withDetail('YouTube rejected the access token (401).'),
        statusCode: statusCode,
        reason: reason,
      );
    }
    if (statusCode == 404 || statusCode == 410) {
      return YouTubeUploadException(
        YouTubeErrorKind.sessionExpired,
        'The YouTube upload session is no longer valid ($statusCode).',
        statusCode: statusCode,
        reason: reason,
      );
    }
    if (statusCode >= 500) {
      return YouTubeUploadException(
        YouTubeErrorKind.server,
        withDetail('YouTube returned a server error ($statusCode).'),
        statusCode: statusCode,
        reason: reason,
      );
    }
    return YouTubeUploadException(
      YouTubeErrorKind.other,
      withDetail(
        'YouTube rejected the request (HTTP $statusCode'
        '${reason == null ? '' : ', $reason'}).',
      ),
      statusCode: statusCode,
      reason: reason,
    );
  }

  final YouTubeErrorKind kind;
  final String message;
  final int? statusCode;

  /// Google's machine-readable reason, e.g. `quotaExceeded`.
  final String? reason;

  /// Retrying (after a pause and a status query) can help.
  bool get isTransient =>
      kind == YouTubeErrorKind.network || kind == YouTubeErrorKind.server;

  @override
  String toString() => 'YouTubeUploadException($kind): $message';
}

class _GoogleError {
  const _GoogleError({this.reason, this.message});

  final String? reason;
  final String? message;
}

_GoogleError _parseGoogleError(String body) {
  if (body.trim().isEmpty) return const _GoogleError();
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return _GoogleError(message: _shorten(body));
    final error = decoded['error'];
    if (error is String) return _GoogleError(message: error);
    if (error is! Map) return _GoogleError(message: _shorten(body));
    String? reason;
    final errors = error['errors'];
    if (errors is List && errors.isNotEmpty && errors.first is Map) {
      reason = (errors.first as Map)['reason']?.toString();
    }
    reason ??= error['status']?.toString();
    return _GoogleError(reason: reason, message: error['message']?.toString());
  } on FormatException {
    return _GoogleError(message: _shorten(body));
  }
}

String _shorten(String text) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= 200 ? flat : '${flat.substring(0, 200)}…';
}
