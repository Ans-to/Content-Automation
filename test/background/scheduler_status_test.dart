import 'dart:io';

import 'package:content_automation/background/scheduler_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final sample = SchedulerStatus(
    state: SchedulerState.uploading,
    updatedAt: DateTime(2026, 10, 26, 18, 30),
    source: 'service',
    message: 'Uploading to YouTube… 42%',
    nextDue: DateTime(2026, 10, 26, 18, 30),
    wakeupKind: 'exact',
    activeUploadId: 7,
    activeTitle: 'Teaser',
    progress: 0.42,
    lastWatchdogRun: DateTime(2026, 10, 26, 18, 15),
  );

  test('round-trips through a JSON-compatible map', () {
    final map = sample.toMap();
    expect(map['state'], 'uploading');
    expect(map['progress'], 0.42);

    final parsed = SchedulerStatus.fromMap(map);
    expect(parsed.state, SchedulerState.uploading);
    expect(parsed.updatedAt, sample.updatedAt);
    expect(parsed.source, 'service');
    expect(parsed.message, sample.message);
    expect(parsed.nextDue, sample.nextDue);
    expect(parsed.wakeupAt, isNull);
    expect(parsed.wakeupKind, 'exact');
    expect(parsed.activeUploadId, 7);
    expect(parsed.activeTitle, 'Teaser');
    expect(parsed.progress, 0.42);
    expect(parsed.lastWatchdogRun, sample.lastWatchdogRun);
  });

  test('unknown state strings fall back to idle', () {
    expect(SchedulerState.parse('bogus'), SchedulerState.idle);
    expect(SchedulerState.parse(null), SchedulerState.idle);
    expect(SchedulerState.parse('waiting'), SchedulerState.waiting);
    expect(SchedulerState.waiting.label, 'Armed');
  });

  group('FileSchedulerStatusStore', () {
    late Directory dir;
    late FileSchedulerStatusStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('scheduler_status_test');
      store = FileSchedulerStatusStore(directoryOverride: dir);
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    test('reads null when nothing was written yet', () async {
      expect(await store.read(), isNull);
    });

    test('persists and restores a status', () async {
      await store.write(sample);
      final restored = await store.read();
      expect(restored?.state, SchedulerState.uploading);
      expect(restored?.activeTitle, 'Teaser');
      expect(restored?.lastWatchdogRun, sample.lastWatchdogRun);
    });

    test('keeps the last watchdog stamp across unrelated writes', () async {
      await store.markWatchdogRun(DateTime(2026, 10, 26, 18, 15));
      await store.write(
        SchedulerStatus(
          state: SchedulerState.sleeping,
          updatedAt: DateTime(2026, 10, 26, 18, 20),
          source: 'app',
        ),
      );
      final restored = await store.read();
      expect(restored?.state, SchedulerState.sleeping);
      expect(restored?.source, 'app');
      expect(restored?.lastWatchdogRun, DateTime(2026, 10, 26, 18, 15));
    });

    test('survives a corrupt file', () async {
      await File('${dir.path}/scheduler_status.json').writeAsString('{nope');
      expect(await store.read(), isNull);
      await store.write(sample);
      expect((await store.read())?.state, SchedulerState.uploading);
    });
  });

  test('InMemorySchedulerStatusStore mirrors the file store semantics',
      () async {
    final store = InMemorySchedulerStatusStore();
    await store.markWatchdogRun(DateTime(2026, 1, 1));
    await store.write(
      SchedulerStatus(
        state: SchedulerState.idle,
        updatedAt: DateTime(2026, 1, 2),
        source: 'service',
      ),
    );
    expect(store.status?.lastWatchdogRun, DateTime(2026, 1, 1));
    expect(store.status?.source, 'service');
  });
}
