import 'package:content_automation/data/models/enums.dart';
import 'package:content_automation/data/models/scheduled_upload.dart';
import 'package:content_automation/integrations/whatsapp/status_reply_builder.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/in_memory_schedule_repository.dart';

void main() {
  final now = DateTime(2026, 10, 26, 12);
  late InMemoryScheduleRepository repository;
  late StatusReplyBuilder builder;

  setUp(() {
    repository = InMemoryScheduleRepository();
    builder = StatusReplyBuilder(repository, clock: () => now);
  });

  Future<ScheduledUpload> add(
    String title, {
    required DateTime at,
    UploadStatus status = UploadStatus.scheduled,
    PlatformUploadStatus youtube = PlatformUploadStatus.pending,
    PlatformUploadStatus instagram = PlatformUploadStatus.pending,
    double progress = 0,
    String? error,
    DateTime? updatedAt,
  }) => repository.create(
    ScheduledUpload(
      videoPath: '/videos/$title.mp4',
      videoName: '$title.mp4',
      title: title,
      scheduledTime: at,
      status: status,
      youtubeStatus: youtube,
      instagramStatus: instagram,
      uploadProgress: progress,
      errorMessage: error,
      createdAt: now.subtract(const Duration(days: 1)),
      updatedAt: updatedAt ?? now.subtract(const Duration(days: 1)),
    ),
  );

  test('answers when nothing is scheduled', () async {
    expect(await builder.build(), 'No uploads scheduled.');
  });

  test('starts with the "YouTube: … | Instagram: …" line', () async {
    await add('Teaser', at: now.add(const Duration(hours: 2)));
    final reply = await builder.build();
    final lines = reply.split('\n');
    expect(lines.first, 'YouTube: Pending | Instagram: Pending');
    expect(lines[1], startsWith('"Teaser" — scheduled for '));
    expect(lines[1], endsWith('(in 2h).'));
    expect(reply, isNot(contains('Other uploads')));
  });

  test('prefers the upload that is running right now', () async {
    await add('Later', at: now.add(const Duration(hours: 1)));
    await add(
      'Running',
      at: now.subtract(const Duration(minutes: 5)),
      status: UploadStatus.uploading,
      youtube: PlatformUploadStatus.uploading,
      instagram: PlatformUploadStatus.pending,
      progress: 0.42,
    );
    await add(
      'Done',
      at: now.subtract(const Duration(days: 1)),
      status: UploadStatus.completed,
      youtube: PlatformUploadStatus.completed,
      instagram: PlatformUploadStatus.completed,
    );

    final reply = await builder.build();
    final lines = reply.split('\n');
    expect(lines[0], 'YouTube: Uploading (42%) | Instagram: Pending');
    expect(lines[1], '"Running" — uploading, 42% overall.');
    expect(lines[2], '');
    expect(lines[3], 'Other uploads:');
    expect(lines[4], startsWith('• Later — YouTube: Pending | Instagram: Pending'));
    expect(lines[4], contains('scheduled, in 1h'));
    expect(lines[5], '• Done — YouTube: Completed | Instagram: Completed (completed)');
  });

  test('falls back to the most recent finished upload', () async {
    await add(
      'Old failure',
      at: now.subtract(const Duration(days: 3)),
      status: UploadStatus.failed,
      youtube: PlatformUploadStatus.failed,
      instagram: PlatformUploadStatus.notApplicable,
      error: 'quota exceeded',
      updatedAt: now.subtract(const Duration(days: 3)),
    );
    await add(
      'Recent success',
      at: now.subtract(const Duration(hours: 3)),
      status: UploadStatus.completed,
      youtube: PlatformUploadStatus.completed,
      instagram: PlatformUploadStatus.completed,
      updatedAt: now.subtract(const Duration(hours: 2)),
    );

    final reply = await builder.build();
    expect(reply, startsWith('YouTube: Completed | Instagram: Completed\n'));
    expect(reply, contains('"Recent success" — completed'));
    expect(reply, contains('• Old failure — YouTube: Failed | Instagram: N/A (failed)'));
  });

  test('shows the failure reason', () async {
    await add(
      'Broken',
      at: now.subtract(const Duration(hours: 1)),
      status: UploadStatus.failed,
      youtube: PlatformUploadStatus.failed,
      instagram: PlatformUploadStatus.pending,
      error: 'file missing',
    );
    expect(
      await builder.build(),
      'YouTube: Failed | Instagram: Pending\n"Broken" — failed: file missing',
    );
  });

  test('filters by title and explains misses', () async {
    await add('Launch teaser', at: now.add(const Duration(hours: 1)));
    await add('Weekly vlog', at: now.add(const Duration(hours: 2)));

    final filtered = await builder.build(filter: 'vlog');
    expect(filtered, contains('"Weekly vlog"'));
    expect(filtered, isNot(contains('Launch teaser')));

    expect(
      await builder.build(filter: 'podcast'),
      'No upload matching "podcast". Reply "Status" for all uploads.',
    );
  });

  test('caps the list of other uploads', () async {
    for (var i = 0; i < 7; i++) {
      await add('Clip $i', at: now.add(Duration(hours: i + 1)));
    }
    final reply = await builder.build();
    expect('•'.allMatches(reply).length, StatusReplyBuilder.maxOthers);
    expect(reply, endsWith('…and 2 more.'));
  });
}
