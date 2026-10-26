import 'dart:convert';

import 'package:content_automation/data/models/enums.dart';
import 'package:content_automation/data/models/scheduled_upload.dart';
import 'package:content_automation/integrations/whatsapp/inbox_cursor_store.dart';
import 'package:content_automation/integrations/whatsapp/inbox_service.dart';
import 'package:content_automation/integrations/whatsapp/whatsapp_client.dart';
import 'package:content_automation/services/secure_key_value_store.dart';
import 'package:content_automation/services/settings_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../helpers/in_memory_schedule_repository.dart';

void main() {
  final now = DateTime.utc(2026, 10, 26, 12);
  const configured = AppSettings(
    whatsappEndpoint: 'https://agent.example.com/api',
    whatsappApiKey: 'k',
    whatsappRecipient: '923001234567',
  );

  late InMemoryScheduleRepository repository;
  late SettingsService settings;
  late InMemoryInboxCursorStore cursorStore;
  late InMemoryInboxLock lock;
  late List<http.Request> requests;
  late List<Map<String, Object?>> inbox;
  late int inboxStatus;

  WhatsAppInboxService buildService() => WhatsAppInboxService(
    settingsService: settings,
    repository: repository,
    client: WhatsAppHttpClient(
      client: MockClient((request) async {
        requests.add(request);
        if (request.method == 'GET') {
          return http.Response(jsonEncode({'messages': inbox}), inboxStatus);
        }
        return http.Response('{"ok":true}', 200);
      }),
      clock: () => now,
    ),
    cursorStore: cursorStore,
    lock: lock,
    clock: () => now,
  );

  List<http.Request> posts() =>
      requests.where((r) => r.method == 'POST').toList();

  Map<String, dynamic> body(http.Request request) =>
      jsonDecode(request.body) as Map<String, dynamic>;

  setUp(() async {
    repository = InMemoryScheduleRepository();
    settings = SettingsService(
      store: InMemoryKeyValueStore(),
      buildDefaults: const AppSettings(),
    );
    await settings.save(configured);
    cursorStore = InMemoryInboxCursorStore();
    lock = InMemoryInboxLock();
    requests = [];
    inbox = [];
    inboxStatus = 200;
    await repository.create(
      ScheduledUpload(
        videoPath: '/v.mp4',
        videoName: 'v.mp4',
        title: 'Teaser',
        scheduledTime: now.add(const Duration(hours: 1)),
        createdAt: now,
        updatedAt: now,
      ),
    );
  });

  test('skips when the agent is not configured', () async {
    await settings.save(const AppSettings());
    final result = await buildService().pollOnce();
    expect(result.outcome, InboxPollOutcome.skipped);
    expect(requests, isEmpty);
  });

  test('skips for Cloud API endpoints (no inbox to poll)', () async {
    await settings.save(
      configured.copyWith(
        whatsappEndpoint: 'https://graph.facebook.com/v21.0/1/messages',
      ),
    );
    final result = await buildService().pollOnce();
    expect(result.outcome, InboxPollOutcome.skipped);
    expect(result.detail, contains('no inbox'));
    expect(requests, isEmpty);
  });

  test('answers a "Status" message and remembers it', () async {
    inbox = [
      {
        'id': 'm1',
        'from': '923001234567',
        'text': 'Status',
        'timestamp': now.subtract(const Duration(minutes: 1)).toIso8601String(),
      },
    ];
    final service = buildService();

    final first = await service.pollOnce();
    expect(first.ok, isTrue);
    expect(first.fetched, 1);
    expect(first.replied, 1);

    final get = requests.first;
    expect(get.method, 'GET');
    expect(
      get.url.queryParameters['since'],
      now.subtract(const Duration(minutes: 10)).toIso8601String(),
    );

    final reply = body(posts().single);
    expect(reply['event'], 'status_reply');
    expect(reply['to'], '923001234567');
    expect(reply['text'], startsWith('YouTube: Pending | Instagram: Pending\n'));
    expect(reply['text'], contains('"Teaser"'));

    final cursor = cursorStore.cursor;
    expect(cursor.handledIds, ['m1']);
    expect(cursor.lastTimestamp, now.subtract(const Duration(minutes: 1)));
    expect(cursor.lastCheckedAt, now);
    expect(cursor.replyCount, 1);
    expect(cursor.lastReplyPreview, 'YouTube: Pending | Instagram: Pending');
    expect(cursor.lastError, isNull);

    // Same message again (agent ignores `since`): no second reply.
    final second = await service.pollOnce();
    expect(second.replied, 0);
    expect(posts(), hasLength(1));
    // The next `since` is the newest timestamp minus the skew allowance.
    expect(
      requests.last.url.queryParameters['since'],
      now.subtract(const Duration(minutes: 3)).toIso8601String(),
    );
  });

  test('replies to the sender and honours a title filter', () async {
    await repository.create(
      ScheduledUpload(
        videoPath: '/w.mp4',
        videoName: 'w.mp4',
        title: 'Weekly vlog',
        scheduledTime: now.add(const Duration(hours: 2)),
        status: UploadStatus.uploading,
        youtubeStatus: PlatformUploadStatus.uploading,
        instagramStatus: PlatformUploadStatus.notApplicable,
        uploadProgress: 0.25,
        createdAt: now,
        updatedAt: now,
      ),
    );
    inbox = [
      {
        'id': 'm2',
        'from': '+92 300 1234567',
        'text': 'status vlog',
        'timestamp': now.millisecondsSinceEpoch,
      },
    ];
    await buildService().pollOnce();
    final reply = body(posts().single);
    expect(reply['to'], '+92 300 1234567');
    expect(reply['text'], startsWith('YouTube: Uploading (25%) | Instagram: N/A'));
    expect(reply['text'], isNot(contains('Teaser')));
  });

  test('ignores other senders, old messages and non-status chatter', () async {
    inbox = [
      {
        'id': 'stranger',
        'from': '15550001111',
        'text': 'Status',
        'timestamp': now.toIso8601String(),
      },
      {
        'id': 'old',
        'from': '923001234567',
        'text': 'Status',
        'timestamp': now.subtract(const Duration(hours: 5)).toIso8601String(),
      },
      {
        'id': 'chat',
        'from': '923001234567',
        'text': 'thanks!',
        'timestamp': now.toIso8601String(),
      },
    ];
    final result = await buildService().pollOnce();
    expect(result.fetched, 3);
    expect(result.replied, 0);
    expect(posts(), isEmpty);
    expect(cursorStore.cursor.handledIds, ['stranger', 'old', 'chat']);
  });

  test('matches local-format sender numbers', () async {
    inbox = [
      {
        'id': 'm3',
        'from': '03001234567',
        'text': 'Status',
        'timestamp': now.toIso8601String(),
      },
    ];
    final result = await buildService().pollOnce();
    expect(result.replied, 1);
  });

  test('answers messages without a sender or timestamp', () async {
    inbox = [
      {'text': 'STATUS'},
    ];
    final result = await buildService().pollOnce();
    expect(result.replied, 1);
    expect(body(posts().single)['to'], '923001234567');
    expect(cursorStore.cursor.handledIds.single, startsWith('synthetic:'));
  });

  test('records fetch failures in the cursor', () async {
    inboxStatus = 500;
    final result = await buildService().pollOnce();
    expect(result.outcome, InboxPollOutcome.failed);
    expect(result.detail, contains('HTTP 500'));
    expect(cursorStore.cursor.lastError, contains('HTTP 500'));
    expect(cursorStore.cursor.lastCheckedAt, now);
    expect(posts(), isEmpty);
  });

  test('a failed reply is retried on the next poll', () async {
    var failReply = true;
    final service = WhatsAppInboxService(
      settingsService: settings,
      repository: repository,
      client: WhatsAppHttpClient(
        client: MockClient((request) async {
          requests.add(request);
          if (request.method == 'GET') {
            return http.Response(
              jsonEncode([
                {
                  'id': 'm4',
                  'from': '923001234567',
                  'text': 'Status',
                  'timestamp': now.toIso8601String(),
                },
              ]),
              200,
            );
          }
          return http.Response('busy', failReply ? 503 : 200);
        }),
      ),
      cursorStore: cursorStore,
      lock: lock,
      clock: () => now,
    );

    final first = await service.pollOnce();
    expect(first.ok, isTrue);
    expect(first.replied, 0);
    expect(first.detail, contains('Reply failed'));
    expect(cursorStore.cursor.lastError, contains('HTTP 503'));
    expect(cursorStore.cursor.handledIds, isEmpty);

    failReply = false;
    final second = await service.pollOnce();
    expect(second.replied, 1);
    expect(cursorStore.cursor.handledIds, ['m4']);
    expect(cursorStore.cursor.lastError, isNull);
  });

  test('does not run while another poll holds the lock', () async {
    final service = buildService();
    final blocked = await lock.tryRun(() => service.pollOnce());
    expect(blocked?.outcome, InboxPollOutcome.skipped);
    expect(blocked?.detail, contains('Another poll'));
    expect(lock.skipped, 1);
    expect(requests, isEmpty);
  });

  test('sameNumber tolerates formatting differences', () {
    expect(WhatsAppInboxService.sameNumber('923001234567', '923001234567'), isTrue);
    expect(WhatsAppInboxService.sameNumber('03001234567', '923001234567'), isTrue);
    expect(WhatsAppInboxService.sameNumber('+92 300 1234567', '923001234567'), isTrue);
    expect(WhatsAppInboxService.sameNumber('923001234567', '0092 300 1234567'), isTrue);
    expect(WhatsAppInboxService.sameNumber('923001234568', '923001234567'), isFalse);
    expect(WhatsAppInboxService.sameNumber('4567', '923001234567'), isFalse);
    expect(WhatsAppInboxService.sameNumber('', '923001234567'), isFalse);
  });

  test('isEnabled mirrors the configuration', () async {
    expect(await buildService().isEnabled(), isTrue);
    await settings.save(const AppSettings());
    expect(await buildService().isEnabled(), isFalse);
  });
}
