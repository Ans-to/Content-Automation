import 'package:content_automation/data/models/enums.dart';
import 'package:content_automation/data/models/scheduled_upload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final scheduledTime = DateTime(2026, 11, 1, 18, 30);

  ScheduledUpload sample({UploadPlatform platform = UploadPlatform.both}) =>
      ScheduledUpload.create(
        videoPath: '/data/user/0/app/files/scheduled_videos/abc.mp4',
        videoName: 'reel.mp4',
        videoSizeBytes: 12345678,
        title: '  My title  ',
        description: 'A description',
        tags: const ['Flutter', 'flutter', ' dart ', ''],
        scheduledTime: scheduledTime,
        platform: platform,
      );

  group('ScheduledUpload.create', () {
    test('trims metadata and normalises tags', () {
      final upload = sample();
      expect(upload.title, 'My title');
      expect(upload.tags, ['Flutter', 'dart']);
      expect(upload.tagsAsString, 'Flutter, dart');
      expect(upload.status, UploadStatus.scheduled);
      expect(upload.uploadProgress, 0);
    });

    test('derives per-platform statuses from the platform', () {
      final both = sample();
      expect(both.youtubeStatus, PlatformUploadStatus.pending);
      expect(both.instagramStatus, PlatformUploadStatus.pending);

      final youtubeOnly = sample(platform: UploadPlatform.youtube);
      expect(youtubeOnly.youtubeStatus, PlatformUploadStatus.pending);
      expect(youtubeOnly.instagramStatus, PlatformUploadStatus.notApplicable);
      expect(youtubeOnly.statusSummary, 'YouTube: Pending | Instagram: N/A');
    });
  });

  test('toMap / fromMap round-trips every field', () {
    final original = sample().copyWith(
      id: 7,
      status: UploadStatus.failed,
      youtubeStatus: PlatformUploadStatus.completed,
      instagramStatus: PlatformUploadStatus.failed,
      youtubeVideoId: 'yt123',
      uploadProgress: 0.5,
      errorMessage: 'boom',
      retryCount: 2,
    );
    final restored = ScheduledUpload.fromMap(original.toMap());
    expect(restored, original);
    expect(restored.scheduledTime, scheduledTime);
    expect(restored.tags, ['Flutter', 'dart']);
    expect(restored.instagramMediaId, isNull);
  });

  test('fromMap tolerates unknown enum values', () {
    final map = sample().toMap()
      ..['status'] = 'weird'
      ..['platform'] = 'tiktok'
      ..['youtube_status'] = null;
    final restored = ScheduledUpload.fromMap(map);
    expect(restored.status, UploadStatus.scheduled);
    expect(restored.platform, UploadPlatform.both);
    expect(restored.youtubeStatus, PlatformUploadStatus.pending);
  });

  test('copyWith can clear nullable fields', () {
    final withError = sample().copyWith(errorMessage: 'x', youtubeVideoId: 'y');
    expect(withError.errorMessage, 'x');
    final cleared = withError.copyWith(errorMessage: null, youtubeVideoId: null);
    expect(cleared.errorMessage, isNull);
    expect(cleared.youtubeVideoId, isNull);
    // Not passing the argument keeps the value.
    expect(withError.copyWith(title: 'z').errorMessage, 'x');
  });

  test('isDue only for scheduled uploads whose time has passed', () {
    final upload = sample();
    expect(upload.isDue(scheduledTime.subtract(const Duration(minutes: 1))), isFalse);
    expect(upload.isDue(scheduledTime), isTrue);
    expect(
      upload.copyWith(status: UploadStatus.completed).isDue(scheduledTime),
      isFalse,
    );
  });

  group('tags', () {
    test('parseTags splits on commas', () {
      expect(ScheduledUpload.parseTags('a, b,,c ,A'), ['a', 'b', 'c']);
      expect(ScheduledUpload.parseTags(null), isEmpty);
      expect(ScheduledUpload.parseTags('   '), isEmpty);
    });
  });

  group('UploadPlatform', () {
    test('fromSelection', () {
      expect(
        UploadPlatform.fromSelection(youtube: true, instagram: true),
        UploadPlatform.both,
      );
      expect(
        UploadPlatform.fromSelection(youtube: true, instagram: false),
        UploadPlatform.youtube,
      );
      expect(
        UploadPlatform.fromSelection(youtube: false, instagram: true),
        UploadPlatform.instagram,
      );
      expect(
        () => UploadPlatform.fromSelection(youtube: false, instagram: false),
        throwsArgumentError,
      );
    });

    test('includes helpers', () {
      expect(UploadPlatform.both.includesYouTube, isTrue);
      expect(UploadPlatform.both.includesInstagram, isTrue);
      expect(UploadPlatform.youtube.includesInstagram, isFalse);
      expect(UploadPlatform.instagram.includesYouTube, isFalse);
    });
  });

  test('UploadStatus helpers', () {
    expect(UploadStatus.completed.isTerminal, isTrue);
    expect(UploadStatus.failed.isTerminal, isTrue);
    expect(UploadStatus.uploading.isActive, isTrue);
    expect(UploadStatus.scheduled.isEditable, isTrue);
    expect(UploadStatus.failed.isEditable, isTrue);
    expect(UploadStatus.uploading.isEditable, isFalse);
  });
}
