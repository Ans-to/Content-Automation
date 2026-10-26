import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../../core/constants.dart';
import 'google_auth_client.dart';
import 'youtube_errors.dart';

/// Where the transfer stands according to YouTube.
class ResumeStatus {
  const ResumeStatus.incomplete(this.nextOffset) : video = null;

  const ResumeStatus.completed(Map<String, Object?> this.video)
    : nextOffset = -1;

  /// First byte YouTube has not received yet.
  final int nextOffset;

  /// Set when YouTube already finished the upload (the JSON `Video`).
  final Map<String, Object?>? video;

  bool get isCompleted => video != null;
}

/// Google's resumable upload protocol for `videos.insert`, written so that a
/// transfer survives network drops, token expiry and even the process being
/// killed (the caller persists the session URI and calls [queryStatus] to
/// continue).
///
/// https://developers.google.com/youtube/v3/guides/using_resumable_upload_protocol
class YouTubeResumableUpload {
  YouTubeResumableUpload({
    required http.Client client,
    required AccessTokenSource tokens,
    this.chunkSize = AppConstants.youtubeUploadChunkSize,
    this.maxAttempts = 8,
    this.chunkTimeout = const Duration(minutes: 8),
    this.requestTimeout = const Duration(seconds: 60),
    Future<void> Function(Duration delay)? sleep,
    Duration Function(int attempt)? backoff,
    Uri? endpoint,
  }) : assert(chunkSize % _chunkGranularity == 0, 'chunk must be n × 256 KiB'),
       _client = client,
       _tokens = tokens,
       _sleep = sleep ?? ((d) => Future<void>.delayed(d)),
       _backoff = backoff ?? defaultBackoff,
       _endpoint = endpoint ?? defaultEndpoint;

  static const int _chunkGranularity = 256 * 1024;

  /// `part=snippet,status` is everything this app sets.
  static final Uri defaultEndpoint = Uri.parse(
    'https://www.googleapis.com/upload/youtube/v3/videos'
    '?uploadType=resumable&part=snippet%2Cstatus',
  );

  /// 2 s, 4 s, 8 s … capped at 2 minutes.
  static Duration defaultBackoff(int attempt) =>
      Duration(seconds: math.min(120, 1 << math.min(attempt, 7)));

  final http.Client _client;
  final AccessTokenSource _tokens;
  final int chunkSize;
  final int maxAttempts;
  final Duration chunkTimeout;
  final Duration requestTimeout;
  final Future<void> Function(Duration delay) _sleep;
  final Duration Function(int attempt) _backoff;
  final Uri _endpoint;

  /// Opens a session; the returned URI accepts the bytes.
  Future<Uri> startSession({
    required Map<String, Object?> metadata,
    required int totalBytes,
    String contentType = 'video/*',
  }) async {
    final body = utf8.encode(jsonEncode(metadata));
    for (var attempt = 1; ; attempt++) {
      final response = await _retryingSend(
        () => http.Request('POST', _endpoint)
          ..headers['Content-Type'] = 'application/json; charset=UTF-8'
          ..headers['X-Upload-Content-Type'] = contentType
          ..headers['X-Upload-Content-Length'] = '$totalBytes'
          ..bodyBytes = body,
        attempt: attempt,
      );
      if (response == null) continue; // transient failure, already waited

      if (response.statusCode == 200 || response.statusCode == 201) {
        final location = _header(response.headers, 'location');
        if (location == null || location.isEmpty) {
          throw const YouTubeUploadException(
            YouTubeErrorKind.other,
            'YouTube did not return an upload session URI.',
          );
        }
        return Uri.parse(location);
      }
      throw YouTubeUploadException.fromResponse(
        response.statusCode,
        response.body,
      );
    }
  }

  /// Asks YouTube how many bytes of the session it already holds.
  Future<ResumeStatus> queryStatus(Uri session, int totalBytes) async {
    for (var attempt = 1; ; attempt++) {
      final response = await _retryingSend(
        () => http.Request('PUT', session)
          ..headers['Content-Range'] = 'bytes */$totalBytes',
        attempt: attempt,
      );
      if (response == null) continue;

      switch (response.statusCode) {
        case 308:
          return ResumeStatus.incomplete(
            _nextOffsetFromRange(_header(response.headers, 'range')),
          );
        case 200:
        case 201:
          return ResumeStatus.completed(_decodeVideo(response.body));
        default:
          throw YouTubeUploadException.fromResponse(
            response.statusCode,
            response.body,
          );
      }
    }
  }

  /// Streams [file] into [session] starting at [startOffset]; returns the
  /// JSON `Video` resource once YouTube acknowledges the last byte.
  ///
  /// [onProgress] receives the cumulative number of bytes sent so far.
  Future<Map<String, Object?>> uploadFile({
    required Uri session,
    required File file,
    required int totalBytes,
    required void Function(int sentBytes) onProgress,
    int startOffset = 0,
    String contentType = 'video/*',
  }) async {
    var offset = startOffset;
    var failures = 0;
    var authRetries = 0;

    while (true) {
      final end = math.min(offset + chunkSize, totalBytes);
      try {
        final response = await _sendChunk(
          session: session,
          file: file,
          offset: offset,
          end: end,
          totalBytes: totalBytes,
          contentType: contentType,
          onProgress: onProgress,
        );

        switch (response.statusCode) {
          case 308:
            // No `Range` header means YouTube kept nothing of this chunk.
            final next = _nextOffsetFromRange(
              _header(response.headers, 'range'),
            );
            if (next <= offset) {
              failures++;
              if (failures > maxAttempts) {
                // Non-transient on purpose: the catch below must not loop.
                throw YouTubeUploadException(
                  YouTubeErrorKind.other,
                  'YouTube keeps discarding the uploaded bytes (stuck at '
                  '$offset of $totalBytes).',
                  statusCode: 308,
                );
              }
              await _sleep(_backoff(failures));
            } else {
              failures = 0;
            }
            offset = next;
            continue;
          case 200:
          case 201:
            onProgress(totalBytes);
            return _decodeVideo(response.body);
          case 401:
            if (++authRetries > 2) {
              throw YouTubeUploadException.fromResponse(401, response.body);
            }
            await _tokens.token(forceRefresh: true);
            continue;
          default:
            throw YouTubeUploadException.fromResponse(
              response.statusCode,
              response.body,
            );
        }
      } on YouTubeUploadException catch (e) {
        if (!e.isTransient) rethrow;
        failures++;
        if (failures > maxAttempts) {
          throw YouTubeUploadException(
            YouTubeErrorKind.network,
            'YouTube upload failed after $maxAttempts attempts: ${e.message}',
            statusCode: e.statusCode,
          );
        }
        await _sleep(_backoff(failures));

        // Re-synchronise with what YouTube actually received.
        try {
          final status = await queryStatus(session, totalBytes);
          if (status.isCompleted) {
            onProgress(totalBytes);
            return status.video!;
          }
          offset = status.nextOffset;
        } on YouTubeUploadException catch (statusError) {
          if (!statusError.isTransient) rethrow;
          // Still offline; keep the current offset and try again later.
        }
      }
    }
  }

  // ---------------------------------------------------------------------------

  /// Sends a replayable request, retrying transient failures with backoff.
  /// Returns `null` when the caller should loop (a wait already happened).
  Future<http.Response?> _retryingSend(
    http.Request Function() build, {
    required int attempt,
  }) async {
    http.Response response;
    try {
      final request = build()
        ..headers['Authorization'] = 'Bearer ${await _tokens.token()}';
      response = await _sendReplayable(request);
      if (response.statusCode == 401) {
        final retry = build()
          ..headers['Authorization'] =
              'Bearer ${await _tokens.token(forceRefresh: true)}';
        response = await _sendReplayable(retry);
      }
    } on YouTubeUploadException catch (e) {
      if (!e.isTransient || attempt >= maxAttempts) rethrow;
      await _sleep(_backoff(attempt));
      return null;
    }
    if (response.statusCode >= 500 && attempt < maxAttempts) {
      await _sleep(_backoff(attempt));
      return null;
    }
    return response;
  }

  Future<http.Response> _sendReplayable(http.Request request) async {
    final streamed = await _timed(_client.send(request), requestTimeout);
    return _timed(http.Response.fromStream(streamed), requestTimeout);
  }

  Future<http.Response> _sendChunk({
    required Uri session,
    required File file,
    required int offset,
    required int end,
    required int totalBytes,
    required String contentType,
    required void Function(int sentBytes) onProgress,
  }) async {
    var cancelled = false;
    var sent = offset;
    // The body is read lazily while the socket accepts it (the HTTP client
    // applies back-pressure), so progress reflects bytes actually sent.
    final request = _ChunkRequest(
      session,
      length: end - offset,
      body: () => file.openRead(offset, end).map((piece) {
        if (cancelled) throw const _ChunkAbortedException();
        sent += piece.length;
        onProgress(sent);
        return piece;
      }),
    );
    request.headers['Authorization'] = 'Bearer ${await _tokens.token()}';
    request.headers['Content-Type'] = contentType;
    request.headers['Content-Range'] = 'bytes $offset-${end - 1}/$totalBytes';

    try {
      final streamed = await _timed(_client.send(request), chunkTimeout);
      return await _timed(http.Response.fromStream(streamed), requestTimeout);
    } finally {
      // Stops the file stream if the request is still being fed (timeout).
      cancelled = true;
    }
  }

  Future<T> _timed<T>(Future<T> future, Duration timeout) async {
    try {
      return await future.timeout(timeout);
    } on TimeoutException {
      throw const YouTubeUploadException(
        YouTubeErrorKind.network,
        'The connection to YouTube stalled.',
      );
    } on SocketException catch (e) {
      throw YouTubeUploadException(
        YouTubeErrorKind.network,
        'Network error while talking to YouTube: ${e.message}',
      );
    } on HandshakeException catch (e) {
      throw YouTubeUploadException(
        YouTubeErrorKind.network,
        'TLS handshake with YouTube failed: ${e.message}',
      );
    } on HttpException catch (e) {
      throw YouTubeUploadException(
        YouTubeErrorKind.network,
        'HTTP error while talking to YouTube: ${e.message}',
      );
    } on http.ClientException catch (e) {
      throw YouTubeUploadException(
        YouTubeErrorKind.network,
        'Connection to YouTube failed: ${e.message}',
      );
    } on _ChunkAbortedException {
      throw const YouTubeUploadException(
        YouTubeErrorKind.network,
        'The upload chunk was aborted.',
      );
    }
  }

  static Map<String, Object?> _decodeVideo(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, Object?>) return decoded;
      if (decoded is Map) return Map<String, Object?>.from(decoded);
    } on FormatException {
      // fall through
    }
    throw const YouTubeUploadException(
      YouTubeErrorKind.other,
      'YouTube finished the upload but returned an unreadable response.',
    );
  }

  /// `Range: bytes=0-524287` → 524288. No header → nothing received yet.
  static int _nextOffsetFromRange(String? range) {
    if (range == null || range.trim().isEmpty) return 0;
    final match = RegExp(r'(\d+)\s*-\s*(\d+)').firstMatch(range);
    if (match == null) return 0;
    return int.parse(match.group(2)!) + 1;
  }

  static String? _header(Map<String, String> headers, String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name) return entry.value;
    }
    return null;
  }
}

/// A PUT whose body is produced on demand from a file range.
class _ChunkRequest extends http.BaseRequest {
  _ChunkRequest(Uri url, {required int length, required this.body})
    : super('PUT', url) {
    contentLength = length;
  }

  final Stream<List<int>> Function() body;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(body());
  }
}

class _ChunkAbortedException implements Exception {
  const _ChunkAbortedException();
}
