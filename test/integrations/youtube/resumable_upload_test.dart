import 'dart:io';
import 'dart:typed_data';

import 'package:content_automation/integrations/youtube/resumable_upload.dart';
import 'package:content_automation/integrations/youtube/youtube_errors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'fake_youtube_server.dart';

void main() {
  const chunk = 256 * 1024; // smallest legal chunk keeps the tests fast
  late Directory tempDir;
  late File video;
  late int totalBytes;
  late FakeYouTubeServer server;
  late ScriptedTokens tokens;
  final sleeps = <Duration>[];

  YouTubeResumableUpload transport({int maxAttempts = 4}) =>
      YouTubeResumableUpload(
        client: server.client,
        tokens: tokens,
        chunkSize: chunk,
        maxAttempts: maxAttempts,
        sleep: (d) async => sleeps.add(d),
        endpoint: server.uploadEndpoint,
      );

  Future<void> writeVideo(int bytes) async {
    totalBytes = bytes;
    final data = Uint8List(bytes);
    for (var i = 0; i < bytes; i++) {
      data[i] = i % 251;
    }
    await video.writeAsBytes(data, flush: true);
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('yt_resumable_');
    video = File('${tempDir.path}/clip.mp4');
    await writeVideo(chunk * 2 + 1000); // 3 chunks, last one partial
    server = FakeYouTubeServer();
    tokens = ScriptedTokens();
    sleeps.clear();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('startSession posts metadata and returns the Location', () async {
    final session = await transport().startSession(
      metadata: {
        'snippet': {'title': 'Hello'},
        'status': {'privacyStatus': 'public'},
      },
      totalBytes: totalBytes,
      contentType: 'video/mp4',
    );

    expect(session.toString(), 'https://fake.upload/session/sess1');
    final request = server.requests.single;
    expect(request.method, 'POST');
    expect(request.url.queryParameters['uploadType'], 'resumable');
    expect(request.url.queryParameters['part'], 'snippet,status');
    expect(request.headers['X-Upload-Content-Length'], '$totalBytes');
    expect(request.headers['X-Upload-Content-Type'], 'video/mp4');
    expect(request.headers['Content-Type'], startsWith('application/json'));
    expect(request.headers['Authorization'], 'Bearer t1');
    expect(server.sessions['sess1']!.metadata['snippet'], {'title': 'Hello'});
  });

  test('uploads the file in chunks with correct Content-Range headers',
      () async {
    final t = transport();
    final session = await t.startSession(
      metadata: const {},
      totalBytes: totalBytes,
    );
    final progress = <int>[];

    final result = await t.uploadFile(
      session: session,
      file: video,
      totalBytes: totalBytes,
      onProgress: progress.add,
    );

    expect(result['id'], 'vid123');
    final puts = server.requests.where((r) => r.method == 'PUT').toList();
    expect(puts.map((r) => r.headers['Content-Range']), [
      'bytes 0-${chunk - 1}/$totalBytes',
      'bytes $chunk-${2 * chunk - 1}/$totalBytes',
      'bytes ${2 * chunk}-${totalBytes - 1}/$totalBytes',
    ]);
    expect(puts.map((r) => r.bodyBytes.length), [chunk, chunk, 1000]);
    // Server received the exact bytes.
    final received = server.sessions['sess1']!.received.toBytes();
    expect(received, await video.readAsBytes());
    // Progress is cumulative, monotonic and ends at the total.
    expect(progress.last, totalBytes);
    for (var i = 1; i < progress.length; i++) {
      expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
    }
    expect(progress.length, greaterThan(3), reason: 'reported per 64 KiB');
  });

  test('a network error mid-way is retried after querying the status',
      () async {
    final t = transport();
    final session = await t.startSession(
      metadata: const {},
      totalBytes: totalBytes,
    );
    // Request 0 = POST, 1 = first chunk, 2 = second chunk → fails.
    server.networkFaults[2] = const SocketException('connection reset');

    final result = await t.uploadFile(
      session: session,
      file: video,
      totalBytes: totalBytes,
      onProgress: (_) {},
    );

    expect(result['id'], 'vid123');
    expect(sleeps, [const Duration(seconds: 2)]);
    final ranges = server.requests
        .where((r) => r.method == 'PUT')
        .map((r) => r.headers['Content-Range'])
        .toList();
    expect(ranges, [
      'bytes 0-${chunk - 1}/$totalBytes',
      'bytes $chunk-${2 * chunk - 1}/$totalBytes', // lost
      'bytes */$totalBytes', // status query
      'bytes $chunk-${2 * chunk - 1}/$totalBytes', // resent
      'bytes ${2 * chunk}-${totalBytes - 1}/$totalBytes',
    ]);
    expect(
      server.sessions['sess1']!.received.toBytes(),
      await video.readAsBytes(),
    );
  });

  test('5xx answers back off and resume from the confirmed offset', () async {
    final t = transport();
    final session = await t.startSession(
      metadata: const {},
      totalBytes: totalBytes,
    );
    // 1 = first chunk (502) → sleep → 2 = status query → 3 = resend (503)
    // → longer sleep → 4 = status query → 5 = resend OK …
    server.faults[1] = (_) => http.Response('bad gateway', 502);
    server.faults[3] = (_) => http.Response('unavailable', 503);

    final result = await t.uploadFile(
      session: session,
      file: video,
      totalBytes: totalBytes,
      onProgress: (_) {},
    );

    expect(result['id'], 'vid123');
    expect(sleeps, [const Duration(seconds: 2), const Duration(seconds: 4)]);
    expect(
      server.sessions['sess1']!.received.toBytes(),
      await video.readAsBytes(),
    );
  });

  test('gives up after maxAttempts transient failures', () async {
    final t = transport(maxAttempts: 2);
    final session = await t.startSession(
      metadata: const {},
      totalBytes: totalBytes,
    );
    for (var i = 1; i < 20; i++) {
      server.networkFaults[i] = const SocketException('offline');
    }

    await expectLater(
      t.uploadFile(
        session: session,
        file: video,
        totalBytes: totalBytes,
        onProgress: (_) {},
      ),
      throwsA(
        isA<YouTubeUploadException>()
            .having((e) => e.kind, 'kind', YouTubeErrorKind.network)
            .having((e) => e.message, 'message', contains('after 2 attempts')),
      ),
    );
  });

  test('a partially stored chunk continues from the Range header', () async {
    final t = transport();
    final session = await t.startSession(
      metadata: const {},
      totalBytes: totalBytes,
    );
    // Server keeps only half of every chunk (always a 256 KiB multiple is not
    // required by the protocol for what the server reports back).
    server.keepOnlyBytesPerChunk = chunk ~/ 2;

    final result = await t.uploadFile(
      session: session,
      file: video,
      totalBytes: totalBytes,
      onProgress: (_) {},
    );

    expect(result['id'], 'vid123');
    expect(
      server.sessions['sess1']!.received.toBytes(),
      await video.readAsBytes(),
    );
    expect(sleeps, isEmpty, reason: 'progress was made, no backoff needed');
  });

  test('401 on a chunk refreshes the token and resends', () async {
    server = FakeYouTubeServer(validTokens: const {'t2'});
    tokens = ScriptedTokens(['t1', 't2']);
    final t = transport();

    // startSession also refreshes once (t1 rejected, t2 accepted).
    final session = await t.startSession(
      metadata: const {},
      totalBytes: totalBytes,
    );
    expect(tokens.refreshes, 1);

    final result = await t.uploadFile(
      session: session,
      file: video,
      totalBytes: totalBytes,
      onProgress: (_) {},
    );
    expect(result['id'], 'vid123');
  });

  test('401 during the transfer triggers a refresh and a retry', () async {
    final t = transport();
    final session = await t.startSession(
      metadata: const {},
      totalBytes: totalBytes,
    );
    server.faults[2] = FakeYouTubeServer.googleError(
      401,
      'Invalid Credentials',
      reason: 'authError',
    );

    final result = await t.uploadFile(
      session: session,
      file: video,
      totalBytes: totalBytes,
      onProgress: (_) {},
    );

    expect(result['id'], 'vid123');
    expect(tokens.refreshes, 1);
    expect(sleeps, isEmpty);
  });

  test('queryStatus reports the next offset, completion and expiry', () async {
    final t = transport();
    final session = await t.startSession(
      metadata: const {},
      totalBytes: totalBytes,
    );

    expect((await t.queryStatus(session, totalBytes)).nextOffset, 0);

    server.sessions['sess1']!.received.add(List.filled(chunk, 1));
    expect((await t.queryStatus(session, totalBytes)).nextOffset, chunk);

    server.sessions['sess1']!.received.add(
      List.filled(totalBytes - chunk, 2),
    );
    final done = await t.queryStatus(session, totalBytes);
    expect(done.isCompleted, isTrue);
    expect(done.video!['id'], 'vid123');

    server.sessions['sess1']!.expired = true;
    await expectLater(
      t.queryStatus(session, totalBytes),
      throwsA(
        isA<YouTubeUploadException>().having(
          (e) => e.kind,
          'kind',
          YouTubeErrorKind.sessionExpired,
        ),
      ),
    );
  });

  test('quota errors are not retried and carry a readable message', () async {
    final t = transport();
    server.faults[0] = FakeYouTubeServer.googleError(
      403,
      'The request cannot be completed because you have exceeded your quota.',
      reason: 'quotaExceeded',
    );

    await expectLater(
      t.startSession(metadata: const {}, totalBytes: totalBytes),
      throwsA(
        isA<YouTubeUploadException>()
            .having((e) => e.kind, 'kind', YouTubeErrorKind.quota)
            .having((e) => e.message, 'message', contains('quota')),
      ),
    );
    expect(sleeps, isEmpty);
    expect(server.requests, hasLength(1));
  });

  test('upload with startOffset skips the bytes YouTube already has',
      () async {
    final t = transport();
    final session = await t.startSession(
      metadata: const {},
      totalBytes: totalBytes,
    );
    final bytes = await video.readAsBytes();
    server.sessions['sess1']!.received.add(bytes.sublist(0, chunk));

    final result = await t.uploadFile(
      session: session,
      file: video,
      totalBytes: totalBytes,
      startOffset: chunk,
      onProgress: (_) {},
    );

    expect(result['id'], 'vid123');
    final puts = server.requests.where((r) => r.method == 'PUT');
    expect(
      puts.first.headers['Content-Range'],
      'bytes $chunk-${2 * chunk - 1}/$totalBytes',
    );
    expect(server.sessions['sess1']!.received.toBytes(), bytes);
  });
}
