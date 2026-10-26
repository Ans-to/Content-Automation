import 'package:content_automation/data/database/app_database.dart';
import 'package:content_automation/data/models/enums.dart';
import 'package:content_automation/data/models/scheduled_upload.dart';
import 'package:content_automation/data/repositories/schedule_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Runs the SQLite repository against a real (in-memory) SQLite engine.
void main() {
  late AppDatabase database;
  late SqliteScheduleRepository repository;

  setUpAll(sqfliteFfiInit);

  setUp(() {
    database = AppDatabase(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    repository = SqliteScheduleRepository(database);
  });

  tearDown(() => database.close());

  ScheduledUpload sample({
    String title = 'Sample',
    DateTime? scheduledTime,
    UploadPlatform platform = UploadPlatform.both,
  }) => ScheduledUpload.create(
    videoPath: '/videos/$title.mp4',
    videoName: '$title.mp4',
    videoSizeBytes: 1000,
    title: title,
    description: 'desc',
    tags: const ['a', 'b'],
    scheduledTime: scheduledTime ?? DateTime(2030, 1, 1, 10),
    platform: platform,
  );

  test('schema is created with foreign keys enabled', () async {
    final db = await database.database;
    final tables = await db.query(
      'sqlite_master',
      columns: ['name'],
      where: "type = 'table'",
    );
    final names = tables.map((r) => r['name']).toSet();
    expect(names, containsAll(['scheduled_uploads', 'upload_events']));

    final pragma = await db.rawQuery('PRAGMA foreign_keys');
    expect(pragma.first.values.first, 1);
  });

  test('create assigns an id and getById returns the same data', () async {
    final created = await repository.create(sample());
    expect(created.id, isNotNull);

    final fetched = await repository.getById(created.id!);
    expect(fetched, created);
    expect(fetched!.tags, ['a', 'b']);
    expect(fetched.youtubeStatus, PlatformUploadStatus.pending);
  });

  test('getAll is ordered by scheduled time', () async {
    await repository.create(
      sample(title: 'later', scheduledTime: DateTime(2030, 1, 3)),
    );
    await repository.create(
      sample(title: 'sooner', scheduledTime: DateTime(2030, 1, 2)),
    );
    final all = await repository.getAll();
    expect(all.map((u) => u.title), ['sooner', 'later']);
  });

  test('update overwrites metadata', () async {
    final created = await repository.create(sample());
    await repository.update(
      created.copyWith(title: 'Renamed', tags: const ['x']),
    );
    final fetched = await repository.getById(created.id!);
    expect(fetched!.title, 'Renamed');
    expect(fetched.tags, ['x']);
    // Timestamps are persisted with millisecond precision, while the in-memory
    // `createdAt` carries microseconds — compare at the stored precision.
    expect(
      fetched.updatedAt.millisecondsSinceEpoch,
      greaterThanOrEqualTo(created.createdAt.millisecondsSinceEpoch),
    );
  });

  test('update without an id throws', () async {
    await expectLater(repository.update(sample()), throwsArgumentError);
  });

  test('getDue returns only scheduled uploads whose time has passed', () async {
    final now = DateTime(2030, 1, 1, 12);
    final due = await repository.create(
      sample(title: 'due', scheduledTime: now.subtract(const Duration(minutes: 1))),
    );
    await repository.create(
      sample(title: 'future', scheduledTime: now.add(const Duration(minutes: 1))),
    );
    final done = await repository.create(
      sample(title: 'done', scheduledTime: now.subtract(const Duration(hours: 1))),
    );
    await repository.updateStatus(done.id!, status: UploadStatus.completed);

    final result = await repository.getDue(now: now);
    expect(result.map((u) => u.id), [due.id]);

    final next = await repository.getNextScheduled(now: now);
    expect(next?.title, 'future');
  });

  test('getByStatus filters', () async {
    final a = await repository.create(sample(title: 'a'));
    await repository.create(sample(title: 'b'));
    await repository.updateStatus(a.id!, status: UploadStatus.failed);

    expect((await repository.getByStatus(UploadStatus.failed)).length, 1);
    expect((await repository.getByStatus(UploadStatus.scheduled)).length, 1);
  });

  test('updateStatus applies partial updates and retry increments', () async {
    final created = await repository.create(sample());
    final id = created.id!;

    await repository.updateStatus(
      id,
      status: UploadStatus.uploading,
      youtubeStatus: PlatformUploadStatus.uploading,
      uploadProgress: 0.25,
    );
    var fetched = (await repository.getById(id))!;
    expect(fetched.status, UploadStatus.uploading);
    expect(fetched.youtubeStatus, PlatformUploadStatus.uploading);
    expect(fetched.instagramStatus, PlatformUploadStatus.pending);
    expect(fetched.uploadProgress, 0.25);
    expect(fetched.title, 'Sample');

    await repository.updateStatus(
      id,
      status: UploadStatus.failed,
      instagramStatus: PlatformUploadStatus.failed,
      errorMessage: 'network down',
      incrementRetryCount: true,
    );
    fetched = (await repository.getById(id))!;
    expect(fetched.status, UploadStatus.failed);
    expect(fetched.errorMessage, 'network down');
    expect(fetched.retryCount, 1);
    expect(fetched.statusSummary, 'YouTube: Uploading | Instagram: Failed');

    await repository.updateStatus(
      id,
      status: UploadStatus.completed,
      youtubeVideoId: 'yt42',
      clearErrorMessage: true,
      uploadProgress: 2, // clamped
    );
    fetched = (await repository.getById(id))!;
    expect(fetched.errorMessage, isNull);
    expect(fetched.youtubeVideoId, 'yt42');
    expect(fetched.uploadProgress, 1);
  });

  test('events are logged newest-first and cascade on delete', () async {
    final created = await repository.create(sample());
    final id = created.id!;

    await repository.logEvent(id, 'first');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await repository.logEvent(id, 'second', level: EventLevel.error);

    final events = await repository.getEvents(id);
    expect(events.map((e) => e.message), ['second', 'first']);
    expect(events.first.level, EventLevel.error);

    await repository.delete(id);
    expect(await repository.getById(id), isNull);
    expect(await repository.getEvents(id), isEmpty);
  });
}
