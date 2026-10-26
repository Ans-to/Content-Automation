import 'dart:convert';
import 'dart:typed_data';

import 'package:content_automation/integrations/youtube/google_auth_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Scripted token source for the transport tests.
class ScriptedTokens implements AccessTokenSource {
  ScriptedTokens([Iterable<String> tokens = const ['t1', 't2', 't3']])
    : _tokens = List.of(tokens);

  final List<String> _tokens;
  final List<bool> calls = [];
  String? current;

  @override
  Future<String> token({bool forceRefresh = false}) async {
    calls.add(forceRefresh);
    if (current == null || forceRefresh) {
      if (_tokens.isEmpty) {
        throw const MissingAuthorizationException('no more tokens');
      }
      current = _tokens.removeAt(0);
    }
    return current!;
  }

  int get refreshes => calls.where((c) => c).length;
}

/// One upload session as the fake server sees it.
class FakeSession {
  FakeSession(this.totalBytes, this.metadata);

  final int totalBytes;
  final Map<String, Object?> metadata;
  final BytesBuilder received = BytesBuilder(copy: true);
  bool expired = false;

  int get bytes => received.length;
}

/// Simulates the YouTube resumable upload endpoint well enough to test the
/// client: session creation, chunked PUTs with `Content-Range`, 308 status
/// answers with `Range`, final JSON, plus scripted faults.
class FakeYouTubeServer {
  FakeYouTubeServer({
    this.validTokens = const {'t1', 't2', 't3'},
    this.videoId = 'vid123',
  });

  final Set<String> validTokens;
  final String videoId;

  final Map<String, FakeSession> sessions = {};
  final List<http.Request> requests = [];

  /// Scripted responses keyed by request index (0-based, counting every
  /// request). A matching entry is returned instead of the normal handling.
  final Map<int, http.Response Function(http.Request request)> faults = {};

  /// Throw this on the given request index (network failure).
  final Map<int, Object> networkFaults = {};

  /// When > 0, the server only stores this many bytes of each chunk (and
  /// answers 308 for the rest), simulating a partially received chunk.
  int keepOnlyBytesPerChunk = 0;

  /// Videos returned by `GET /youtube/v3/videos` (ids → status JSON).
  final Map<String, Map<String, Object?>> videoStatuses = {};

  /// Channel title returned by `GET /youtube/v3/channels?mine=true`.
  String? channelTitle = 'Fake Channel';

  int _nextSession = 1;

  Uri get uploadEndpoint => Uri.parse(
    'https://fake.upload/upload/youtube/v3/videos?uploadType=resumable&part=snippet%2Cstatus',
  );

  String get apiRootUrl => 'https://fake.api/';

  late final http.Client client = MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    final index = requests.length;
    requests.add(request);

    final networkFault = networkFaults.remove(index);
    if (networkFault != null) throw networkFault;
    final fault = faults.remove(index);
    if (fault != null) return fault(request);

    final auth = request.headers['Authorization'] ?? request.headers['authorization'];
    final token = auth?.replaceFirst('Bearer ', '');
    if (token == null || !validTokens.contains(token)) {
      return _error(401, 'Invalid Credentials', reason: 'authError');
    }

    final path = request.url.path;
    if (request.method == 'POST' && path.endsWith('/upload/youtube/v3/videos')) {
      final length = int.parse(request.headers['X-Upload-Content-Length'] ?? request.headers['x-upload-content-length']!);
      final metadata = jsonDecode(request.body) as Map<String, Object?>;
      final id = 'sess${_nextSession++}';
      sessions[id] = FakeSession(length, metadata);
      return http.Response(
        '',
        200,
        headers: {'Location': 'https://fake.upload/session/$id'},
      );
    }

    if (request.method == 'PUT' && path.startsWith('/session/')) {
      final session = sessions[path.substring('/session/'.length)];
      if (session == null || session.expired) {
        return http.Response('Not Found', 404);
      }
      final range = request.headers['Content-Range'] ?? request.headers['content-range']!;
      if (range.startsWith('bytes */')) {
        return _statusResponse(session);
      }
      final match = RegExp(r'bytes (\d+)-(\d+)/(\d+)').firstMatch(range)!;
      final start = int.parse(match.group(1)!);
      final end = int.parse(match.group(2)!);
      if (start != session.bytes) {
        return http.Response(
          'Content-Range start $start does not match ${session.bytes}',
          400,
        );
      }
      var body = request.bodyBytes;
      if (body.length != end - start + 1) {
        return http.Response('Body length mismatch', 400);
      }
      if (keepOnlyBytesPerChunk > 0 && body.length > keepOnlyBytesPerChunk) {
        body = Uint8List.sublistView(body, 0, keepOnlyBytesPerChunk);
      }
      session.received.add(body);
      return _statusResponse(session);
    }

    if (request.method == 'GET' && path.endsWith('/youtube/v3/videos')) {
      final ids = [
        for (final value in request.url.queryParametersAll['id'] ?? const [])
          ...value.split(','),
      ];
      final items = [
        for (final id in ids)
          if (videoStatuses[id] != null) {'id': id, ...videoStatuses[id]!},
      ];
      return http.Response(
        jsonEncode({'kind': 'youtube#videoListResponse', 'items': items}),
        200,
        headers: {'content-type': 'application/json; charset=UTF-8'},
      );
    }

    if (request.method == 'GET' && path.endsWith('/youtube/v3/channels')) {
      final title = channelTitle;
      return http.Response(
        jsonEncode({
          'kind': 'youtube#channelListResponse',
          'items': [
            if (title != null)
              {
                'id': 'UC123',
                'snippet': {'title': title},
              },
          ],
        }),
        200,
        headers: {'content-type': 'application/json; charset=UTF-8'},
      );
    }

    return http.Response('Unexpected ${request.method} ${request.url}', 500);
  }

  http.Response _statusResponse(FakeSession session) {
    if (session.bytes >= session.totalBytes) {
      return http.Response(
        jsonEncode({
          'kind': 'youtube#video',
          'id': videoId,
          'snippet': session.metadata['snippet'],
          'status': session.metadata['status'],
        }),
        200,
        headers: {'content-type': 'application/json; charset=UTF-8'},
      );
    }
    return http.Response(
      '',
      308,
      headers: {
        if (session.bytes > 0) 'Range': 'bytes=0-${session.bytes - 1}',
      },
    );
  }

  static http.Response _error(int status, String message, {String? reason}) =>
      http.Response(
        jsonEncode({
          'error': {
            'code': status,
            'message': message,
            'errors': [
              {'message': message, 'domain': 'global', 'reason': ?reason},
            ],
          },
        }),
        status,
        headers: {'content-type': 'application/json; charset=UTF-8'},
      );

  static http.Response Function(http.Request) googleError(
    int status,
    String message, {
    String? reason,
  }) => (_) => _error(status, message, reason: reason);
}
