import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:content_automation/data/models/enums.dart';
import 'package:content_automation/data/models/scheduled_upload.dart';
import 'package:content_automation/integrations/uploaders/video_uploader.dart';
import 'package:content_automation/integrations/youtube/google_auth_gateway.dart';
import 'package:content_automation/integrations/youtube/youtube_uploader.dart';
import 'package:content_automation/services/settings_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_youtube_server.dart';

void main() {
  const chunk = 256 * 1024;
  late Directory tempDir;
  late File video;
  late FakeYouTubeServer server;
  late InMemoryGoogleAuthGateway auth;
  late List<String> logs;
  late List<double> progress;
  late List<String?> sessions;

  const settings = AppSettings(
    youtubeClientId: 'web-client-id.apps.googleusercontent.com',
    youtubeAccountEmail: 'creator@example.com',
  );

  YouTubeUploader uploader({bool verify = true}) => YouTubeUploader(
    auth: auth,
    client: server.client,
    chunkSize: chunk,
    verifyAfterUpload: verify,
    sleep: (_) async {},
    uploadEndpoint: server.uploadEndpoint,
    apiRootUrl: server.apiRootUrl,
  );

  ScheduledUpload upload({
    String title = 'My <great> video',
    String? youtubeUploadUri,
    String? path,
  }) => ScheduledUpload.create(
    videoPath: path ?? video.path,
    videoName: 'clip.mp4',
    videoSizeBytes: 0,
    title: title,
    description: 'A description',
    tags: const ['flutter', 'content automation'],
    scheduledTime: DateTime(2026, 10, 26, 18),
    platform: UploadPlatform.youtube,
  ).copyWith(id: 7, youtubeUploadUri: youtubeUploadUri);

  Future<void> run(
    ScheduledUpload target, {
    required void Function(UploadOutcome outcome) check,
  }) async {
    final outcome = await uploader().upload(
      target,
      settings: settings,
      onProgress: progress.add,
      log: (m) async => logs.add(m),
      saveSession: (s) async => sessions.add(s),
    );
    check(outcome);
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('yt_uploader_');
    video = File('${tempDir.path}/clip.mp4');
    final bytes = Uint8List(chunk + 4096);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = (i * 7) % 256;
    }
    await video.writeAsBytes(bytes, flush: true);
    server = FakeYouTubeServer()
      ..videoStatuses['vid123'] = {
        'status': {'uploadStatus': 'uploaded', 'privacyStatus': 'public'},
        'processingDetails': {'processingStatus': 'processing'},
      };
    auth = InMemoryGoogleAuthGateway(
      tokens: const ['t1', 't2', 't3'],
    )..authorized = true;
    logs = [];
    progress = [];
    sessions = [];
  });

  tearDown(() => tempDir.delete(recursive: true));

  test('uploads the file with sanitised public metadata', () async {
    final outcome = await uploader().upload(
      upload(),
      settings: settings,
      onProgress: progress.add,
      log: (m) async => logs.add(m),
      saveSession: (s) async => sessions.add(s),
    );

    expect(outcome.succeeded, isTrue, reason: outcome.error);
    expect(outcome.remoteId, 'vid123');

    // The background gateway was initialised with the Web client ID and asked
    // for a token for the stored account.
    expect(auth.initializedWith, settings.youtubeClientId);
    expect(auth.tokenRequests, greaterThanOrEqualTo(1));

    // Metadata as YouTube saw it.
    final session = server.sessions.values.single;
    final snippet = session.metadata['snippet'] as Map;
    final status = session.metadata['status'] as Map;
    expect(snippet['title'], 'My great video');
    expect(snippet['description'], 'A description');
    expect(snippet['tags'], ['flutter', 'content automation']);
    expect(snippet['categoryId'], '22');
    expect(status['privacyStatus'], 'public');
    expect(status['selfDeclaredMadeForKids'], false);
    expect(status.containsKey('publishAt'), isFalse);

    // Whole file arrived.
    expect(session.received.toBytes(), await video.readAsBytes());

    // Session URI persisted while transferring, cleared when done.
    expect(sessions.first, 'https://fake.upload/session/sess1');
    expect(sessions.last, isNull);

    // Progress 0 → 1.
    expect(progress.first, 0);
    expect(progress.last, 1);
    for (var i = 1; i < progress.length; i++) {
      expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
    }

    // Log tells the story including the sanitising and the status check.
    expect(logs.join('\n'), contains('Removed "<" and ">"'));
    expect(logs.join('\n'), contains('session opened'));
    expect(logs.join('\n'), contains('https://youtu.be/vid123'));
    expect(logs.join('\n'), contains('upload uploaded, processing processing'));
    final verify = server.requests.where((r) => r.method == 'GET').single;
    expect(verify.url.queryParametersAll['id'], ['vid123']);
    expect(verify.url.queryParametersAll['part'], ['status', 'processingDetails']);
  });

  test('resumes from the stored session URI', () async {
    // Pretend an earlier run opened the session and sent the first chunk.
    final bytes = await video.readAsBytes();
    server.sessions['resume'] = FakeSession(bytes.length, const {})
      ..received.add(bytes.sublist(0, chunk));

    await run(
      upload(youtubeUploadUri: 'https://fake.upload/session/resume'),
      check: (outcome) => expect(outcome.succeeded, isTrue, reason: outcome.error),
    );

    // No new session was created; the transfer continued at `chunk`.
    expect(server.requests.where((r) => r.method == 'POST'), isEmpty);
    final puts = server.requests.where((r) => r.method == 'PUT').toList();
    expect(puts.first.headers['Content-Range'], 'bytes */${bytes.length}');
    expect(
      puts[1].headers['Content-Range'],
      'bytes $chunk-${bytes.length - 1}/${bytes.length}',
    );
    expect(server.sessions['resume']!.received.toBytes(), bytes);
    expect(logs.join('\n'), contains('Resuming the YouTube upload at'));
    expect(progress.first, closeTo(chunk / bytes.length, 0.001));
    expect(sessions, [null]);
  });

  test('an expired stored session starts over transparently', () async {
    await run(
      upload(youtubeUploadUri: 'https://fake.upload/session/gone'),
      check: (outcome) {
        expect(outcome.succeeded, isTrue, reason: outcome.error);
        expect(outcome.remoteId, 'vid123');
      },
    );
    expect(logs.join('\n'), contains('session expired; starting again'));
    // Cleared the stale URI, stored the new one, cleared it at the end.
    expect(sessions, [null, 'https://fake.upload/session/sess1', null]);
  });

  test('a stored session that already finished is reported as success',
      () async {
    final bytes = await video.readAsBytes();
    server.sessions['done'] = FakeSession(bytes.length, const {})
      ..received.add(bytes);

    await run(
      upload(youtubeUploadUri: 'https://fake.upload/session/done'),
      check: (outcome) {
        expect(outcome.succeeded, isTrue, reason: outcome.error);
        expect(outcome.remoteId, 'vid123');
      },
    );
    expect(server.requests.where((r) => r.method == 'PUT'), hasLength(1));
    expect(progress, [1]);
  });

  test('fails clearly when the client ID or account is missing', () async {
    final noClient = await uploader().upload(
      upload(),
      settings: const AppSettings(youtubeAccountEmail: 'x@y.z'),
      onProgress: (_) {},
      log: (_) async {},
      saveSession: (_) async {},
    );
    expect(noClient.succeeded, isFalse);
    expect(noClient.error, contains('Web OAuth client ID'));

    final noAccount = await uploader().upload(
      upload(),
      settings: const AppSettings(youtubeClientId: 'cid'),
      onProgress: (_) {},
      log: (_) async {},
      saveSession: (_) async {},
    );
    expect(noAccount.succeeded, isFalse);
    expect(noAccount.error, contains('Sign in with Google'));
    expect(server.requests, isEmpty);
  });

  test('fails with a sign-in hint when the device lost authorization',
      () async {
    auth.authorized = false; // e.g. the user revoked access
    final outcome = await uploader().upload(
      upload(),
      settings: settings,
      onProgress: (_) {},
      log: (_) async {},
      saveSession: (_) async {},
    );
    expect(outcome.succeeded, isFalse);
    expect(outcome.error, contains('sign in with Google again'));
    expect(server.requests, isEmpty);
  });

  test('fails when the video file is missing', () async {
    final outcome = await uploader().upload(
      upload(path: '${tempDir.path}/missing.mp4'),
      settings: settings,
      onProgress: (_) {},
      log: (_) async {},
      saveSession: (_) async {},
    );
    expect(outcome.succeeded, isFalse);
    expect(outcome.error, contains('not found'));
  });

  test('quota errors surface as a readable failure', () async {
    server.faults[0] = FakeYouTubeServer.googleError(
      403,
      'quota',
      reason: 'quotaExceeded',
    );
    final outcome = await uploader().upload(
      upload(),
      settings: settings,
      onProgress: (_) {},
      log: (_) async {},
      saveSession: (s) async => sessions.add(s),
    );
    expect(outcome.succeeded, isFalse);
    expect(outcome.error, contains('quota exceeded'));
    expect(sessions, isEmpty);
  });

  test('metadata rejections clear the session so a retry starts fresh',
      () async {
    final target = upload();
    // Session opens fine, the first chunk is rejected as invalid metadata.
    server.faults[1] = FakeYouTubeServer.googleError(
      400,
      'The request metadata specifies an invalid video title.',
      reason: 'invalidTitle',
    );
    final outcome = await uploader().upload(
      target,
      settings: settings,
      onProgress: (_) {},
      log: (_) async {},
      saveSession: (s) async => sessions.add(s),
    );
    expect(outcome.succeeded, isFalse);
    expect(outcome.error, contains('invalidTitle'));
    expect(sessions.last, isNull);
  });

  test('the status check never fails the upload', () async {
    server.videoStatuses.clear();
    final outcome = await uploader().upload(
      upload(),
      settings: settings,
      onProgress: (_) {},
      log: (m) async => logs.add(m),
      saveSession: (_) async {},
    );
    expect(outcome.succeeded, isTrue);
    expect(logs.join('\n'), contains('not visible yet'));
  });

  test('session metadata is valid JSON for the API', () async {
    await uploader(verify: false).upload(
      upload(title: 'x' * 150),
      settings: settings,
      onProgress: (_) {},
      log: (m) async => logs.add(m),
      saveSession: (_) async {},
    );
    final post = server.requests.firstWhere((r) => r.method == 'POST');
    final body = jsonDecode(post.body) as Map<String, Object?>;
    expect(((body['snippet'] as Map)['title'] as String).length, 100);
    expect(logs.join('\n'), contains('Title shortened to 100'));
    expect(server.requests.where((r) => r.method == 'GET'), isEmpty);
  });
}
