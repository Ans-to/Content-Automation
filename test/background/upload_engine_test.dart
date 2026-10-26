import 'package:content_automation/data/models/enums.dart';
import 'package:content_automation/integrations/uploaders/video_uploader.dart';
import 'package:content_automation/services/settings_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/background_fakes.dart';

void main() {
  group('UploadEngine.processDue', () {
    test('runs the full pipeline for a due upload on both platforms', () async {
      final h = EngineHarness()..captureActivity();
      final created = await h.addUpload();
      final id = created.id!;

      expect(await h.engine.processDue(), 1);

      final upload = (await h.repository.getById(id))!;
      expect(upload.status, UploadStatus.completed);
      expect(upload.youtubeStatus, PlatformUploadStatus.completed);
      expect(upload.instagramStatus, PlatformUploadStatus.completed);
      expect(upload.youtubeVideoId, 'yt123');
      expect(upload.instagramMediaId, 'ig456');
      expect(upload.uploadProgress, 1);
      expect(upload.errorMessage, isNull);

      // Local notifications + WhatsApp, in order.
      expect(h.notifier.events, ['starting:$id', 'completed:$id']);
      expect(h.agent.messages, [
        'Time reached. Starting upload for Launch teaser.',
        'Upload completed for Launch teaser.',
      ]);

      // Both uploaders were called with the same upload and loaded settings.
      expect(h.youtube.calls.single.id, id);
      expect(h.instagram.calls.single.id, id);
      expect(h.youtube.lastSettings, isNotNull);

      // Activity feed drives the foreground notification.
      expect(h.activities.first.message, contains('Time reached'));
      expect(h.activities.last.message, 'Completed');
      expect(h.activities.last.progress, 1);
      // Progress is scaled across the two platforms (YouTube 0..0.5).
      final progressValues = h.activities
          .map((a) => a.progress)
          .whereType<double>()
          .toList();
      expect(progressValues, contains(0.25));
      expect(progressValues, contains(0.75));

      final log = await h.eventMessages(id);
      expect(log.first, startsWith('Time reached ('));
      expect(log, contains(contains('WhatsApp: sent "Time reached.')));
      expect(log, contains(contains('YouTube upload finished (id yt123)')));
      expect(log, contains(startsWith('All uploads completed.')));
      expect(log.last, 'WhatsApp: completion message sent.');
    });

    test('persists the uploader session while transferring', () async {
      String? sessionDuringUpload;
      late final EngineHarness h;
      h = EngineHarness(
        uploaders: {
          UploadPlatform.youtube: FakeUploader(
            UploadPlatform.youtube,
            remoteId: 'yt1',
            sessionToSave: 'https://upload.example/session/1',
            afterSessionSaved: (upload) async {
              final row = await h.repository.getById(upload.id!);
              sessionDuringUpload = row!.youtubeUploadUri;
            },
          ),
        },
      );
      final id = (await h.addUpload(platform: UploadPlatform.youtube)).id!;

      await h.engine.processDue();

      expect(sessionDuringUpload, 'https://upload.example/session/1');
      final upload = (await h.repository.getById(id))!;
      expect(upload.youtubeUploadUri, isNull, reason: 'cleared when finished');
      expect(upload.status, UploadStatus.completed);
    });

    test('progress writes are throttled but 100% always lands', () async {
      final h = EngineHarness(
        progressWriteInterval: const Duration(seconds: 5),
        uploaders: {
          UploadPlatform.youtube: FakeUploader(
            UploadPlatform.youtube,
            remoteId: 'yt1',
            progressSteps: List.generate(100, (i) => (i + 1) / 100),
          ),
        },
      )..captureActivity();
      final id = (await h.addUpload(platform: UploadPlatform.youtube)).id!;

      await h.engine.processDue();

      // 100 callbacks → far fewer rows (first, every 5 %, and the final one).
      final progressWrites = h.repository.statusWrites;
      expect(progressWrites, lessThan(40));
      expect((await h.repository.getById(id))!.uploadProgress, 1);
      // The notification feed still saw every step.
      expect(
        h.activities.where((a) => a.progress != null).length,
        greaterThanOrEqualTo(100),
      );
    });

    test('ignores uploads whose time has not come', () async {
      final h = EngineHarness();
      await h.addUpload(inFuture: const Duration(minutes: 5));

      expect(await h.engine.processDue(), 0);
      expect(h.notifier.events, isEmpty);
      expect(h.youtube.calls, isEmpty);

      h.clock.advance(const Duration(minutes: 5));
      expect(await h.engine.processDue(), 1);
    });

    test('a failing platform marks the upload failed and alerts', () async {
      final h = EngineHarness(
        uploaders: {
          UploadPlatform.instagram: FakeUploader(
            UploadPlatform.instagram,
            error: 'Instagram: token expired',
          ),
        },
      );
      final id = (await h.addUpload()).id!;

      await h.engine.processDue();

      final upload = (await h.repository.getById(id))!;
      expect(upload.status, UploadStatus.failed);
      expect(upload.youtubeStatus, PlatformUploadStatus.completed);
      expect(upload.instagramStatus, PlatformUploadStatus.failed);
      expect(upload.errorMessage, 'Instagram: token expired');
      expect(h.notifier.events.last, 'failed:$id:Instagram: token expired');
      expect(
        h.agent.messages.last,
        'Upload failed for Launch teaser: Instagram: token expired',
      );
      expect(upload.statusSummary, 'YouTube: Completed | Instagram: Failed');
    });

    test('an uploader that throws is treated as a failure', () async {
      final h = EngineHarness(
        uploaders: {
          UploadPlatform.youtube: FakeUploader(
            UploadPlatform.youtube,
            throwError: StateError('boom'),
          ),
        },
      );
      final id = (await h.addUpload(platform: UploadPlatform.youtube)).id!;

      await h.engine.processDue();

      final upload = (await h.repository.getById(id))!;
      expect(upload.status, UploadStatus.failed);
      expect(upload.errorMessage, contains('YouTube upload crashed'));
      expect(upload.instagramStatus, PlatformUploadStatus.notApplicable);
      expect(h.instagram.calls, isEmpty);
    });

    test('a missing video file fails fast without calling uploaders', () async {
      final h = EngineHarness(fileExistsInitially: false);
      final id = (await h.addUpload()).id!;

      await h.engine.processDue();

      final upload = (await h.repository.getById(id))!;
      expect(upload.status, UploadStatus.failed);
      expect(upload.errorMessage, contains('no longer on this device'));
      expect(h.youtube.calls, isEmpty);
      // The "time reached" notification still went out first.
      expect(h.notifier.events.first, 'starting:$id');
      expect(h.agent.messages.first, startsWith('Time reached.'));
    });

    test('placeholder uploaders fail with a clear message', () async {
      final h = EngineHarness();
      final id = (await h.addUpload(platform: UploadPlatform.instagram)).id!;
      const placeholder = UnavailableUploader(
        UploadPlatform.instagram,
        arrivesIn: 'Phase 5',
      );
      final logged = <String>[];
      final outcome = await placeholder.upload(
        (await h.repository.getById(id))!,
        settings: const AppSettings(),
        onProgress: (_) {},
        log: (message) async {
          logged.add(message);
        },
      );
      expect(outcome.succeeded, isFalse);
      expect(outcome.error, contains('Phase 5'));
      expect(logged.single, contains('not part of this build'));
    });

    test('WhatsApp problems are logged but never block the upload', () async {
      final h = EngineHarness(
        agent: RecordingWhatsAppAgent(failWith: Exception('agent down')),
      );
      final id = (await h.addUpload()).id!;

      await h.engine.processDue();

      expect((await h.repository.getById(id))!.status, UploadStatus.completed);
      final log = await h.eventMessages(id);
      expect(log, contains(contains('"Time reached" message failed')));
    });

    test('an unconfigured agent is skipped with a warning in the log', () async {
      final h = EngineHarness(
        agent: RecordingWhatsAppAgent(configured: false),
      );
      final id = (await h.addUpload()).id!;

      await h.engine.processDue();

      expect(h.agent.messages, isEmpty);
      final log = await h.eventMessages(id);
      expect(log, contains(contains('WhatsApp agent not configured')));
    });

    test('claim() prevents two isolates from processing the same upload',
        () async {
      final h = EngineHarness();
      final id = (await h.addUpload()).id!;

      expect(
        await h.repository.claim(
          id,
          from: UploadStatus.scheduled,
          to: UploadStatus.triggered,
        ),
        isTrue,
      );
      expect(
        await h.repository.claim(
          id,
          from: UploadStatus.scheduled,
          to: UploadStatus.triggered,
        ),
        isFalse,
      );
      // The engine sees it is no longer "scheduled" and leaves it alone.
      expect(await h.engine.processDue(), 0);
    });
  });

  group('UploadEngine.recoverInterrupted', () {
    test('resumes a stale in-flight upload where it stopped', () async {
      // The in-memory repository stamps updatedAt with the real clock, so the
      // harness clock starts from "now" and is then moved forward.
      final h = EngineHarness(now: DateTime.now());
      final id = (await h.addUpload()).id!;
      // YouTube already finished, Instagram was mid-flight when the process
      // died; a YouTube session URI is still stored from the first attempt.
      await h.repository.updateStatus(
        id,
        status: UploadStatus.uploading,
        youtubeStatus: PlatformUploadStatus.completed,
        youtubeVideoId: 'yt-old',
        instagramStatus: PlatformUploadStatus.uploading,
        uploadProgress: 0.7,
      );
      h.clock.advance(const Duration(hours: 1));

      expect(await h.engine.recoverInterrupted(), 1);

      final upload = (await h.repository.getById(id))!;
      expect(upload.status, UploadStatus.completed);
      expect(upload.retryCount, 1);
      expect(upload.youtubeVideoId, 'yt-old', reason: 'not uploaded twice');
      expect(upload.instagramMediaId, 'ig456');
      expect(upload.youtubeUploadUri, isNull);
      expect(h.youtube.calls, isEmpty, reason: 'completed platform skipped');
      expect(h.instagram.calls.single.id, id);

      // No duplicate "Time reached" message; completion is announced once.
      expect(h.agent.messages, ['Upload completed for Launch teaser.']);
      expect(h.notifier.events, ['completed:$id']);

      final log = await h.eventMessages(id);
      expect(log, contains(contains('Resuming — attempt 1 of 3')));
      expect(log, contains('YouTube upload had already finished; skipping.'));
    });

    test('the uploader receives the stored session for a real resume',
        () async {
      final h = EngineHarness(now: DateTime.now(), uploaders: {
        UploadPlatform.youtube: FakeUploader(
          UploadPlatform.youtube,
          remoteId: 'yt-resumed',
        ),
      });
      final id = (await h.addUpload(platform: UploadPlatform.youtube)).id!;
      await h.repository.updateStatus(
        id,
        status: UploadStatus.uploading,
        youtubeStatus: PlatformUploadStatus.uploading,
        youtubeUploadUri: 'https://upload.example/session/abc',
      );
      h.clock.advance(const Duration(hours: 1));

      expect(await h.engine.recoverInterrupted(), 1);

      expect(
        h.youtube.calls.single.youtubeUploadUri,
        'https://upload.example/session/abc',
      );
      final upload = (await h.repository.getById(id))!;
      expect(upload.status, UploadStatus.completed);
      expect(upload.youtubeVideoId, 'yt-resumed');
      expect(upload.youtubeUploadUri, isNull);
    });

    test('gives up after the resume budget is spent', () async {
      final h = EngineHarness(now: DateTime.now(), maxResumeAttempts: 2);
      final id = (await h.addUpload()).id!;
      await h.repository.updateStatus(
        id,
        status: UploadStatus.uploading,
        youtubeStatus: PlatformUploadStatus.uploading,
      );
      // Two earlier resumes already happened.
      await h.repository.updateStatus(id, incrementRetryCount: true);
      await h.repository.updateStatus(id, incrementRetryCount: true);
      h.clock.advance(const Duration(hours: 1));

      expect(await h.engine.recoverInterrupted(), 1);

      final upload = (await h.repository.getById(id))!;
      expect(upload.status, UploadStatus.failed);
      expect(upload.youtubeStatus, PlatformUploadStatus.failed);
      expect(upload.instagramStatus, PlatformUploadStatus.pending);
      expect(upload.errorMessage, contains('Interrupted'));
      expect(upload.errorMessage, contains('2 times'));
      expect(h.youtube.calls, isEmpty);
      expect(h.notifier.events, ['failed:$id:${upload.errorMessage}']);
      expect(h.agent.messages.single, startsWith('Upload failed'));
    });

    test('fails immediately when the video file is gone', () async {
      final h = EngineHarness(now: DateTime.now());
      final id = (await h.addUpload()).id!;
      await h.repository.updateStatus(id, status: UploadStatus.uploading);
      h.fileExists = false;
      h.clock.advance(const Duration(hours: 1));

      expect(await h.engine.recoverInterrupted(), 1);

      final upload = (await h.repository.getById(id))!;
      expect(upload.status, UploadStatus.failed);
      expect(upload.errorMessage, contains('no longer on this device'));
      expect(h.youtube.calls, isEmpty);
    });

    test('staleAfter overrides the default window', () async {
      final h = EngineHarness(now: DateTime.now());
      final id = (await h.addUpload()).id!;
      await h.repository.updateStatus(id, status: UploadStatus.uploading);
      h.clock.advance(const Duration(minutes: 5));

      expect(await h.engine.recoverInterrupted(), 0);
      expect(
        await h.engine.recoverInterrupted(
          staleAfter: const Duration(minutes: 3),
        ),
        1,
      );
      expect((await h.repository.getById(id))!.status, UploadStatus.completed);
    });

    test('leaves recently updated uploads alone', () async {
      final h = EngineHarness(now: DateTime.now());
      final id = (await h.addUpload()).id!;
      await h.repository.updateStatus(id, status: UploadStatus.uploading);

      expect(await h.engine.recoverInterrupted(), 0);
      expect((await h.repository.getById(id))!.status, UploadStatus.uploading);
    });

    test('scheduled uploads are never touched', () async {
      final h = EngineHarness(now: DateTime.now());
      await h.addUpload(inFuture: const Duration(hours: 2));
      h.clock.advance(const Duration(hours: 1));

      expect(await h.engine.recoverInterrupted(), 0);
    });
  });
}
