import 'dart:convert';

import 'package:content_automation/background/watchdog_task.dart';
import 'package:content_automation/data/models/enums.dart';
import 'package:content_automation/integrations/whatsapp/inbox_cursor_store.dart';
import 'package:content_automation/integrations/whatsapp/inbox_service.dart';
import 'package:content_automation/integrations/whatsapp/whatsapp_client.dart';
import 'package:content_automation/services/secure_key_value_store.dart';
import 'package:content_automation/services/settings_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../helpers/background_fakes.dart';
import '../helpers/in_memory_schedule_repository.dart';

void main() {
  test('nothing due: only stamps the watchdog run', () async {
    final h = EngineHarness();
    await h.addUpload(inFuture: const Duration(hours: 4));

    final inline = await WatchdogTask(h.runtime, clock: h.clock.call)
        .run(trigger: 'watchdog');

    expect(inline, isFalse);
    expect(h.bridge.serviceStartRequests, 0);
    expect(h.statusStore.status?.lastWatchdogRun, h.clock.now);
    // The alarm was (re)armed on the way.
    expect(h.bridge.scheduledWakeup, isNotNull);
  });

  test('due soon and service down: starts the foreground service', () async {
    final h = EngineHarness();
    await h.addUpload(inFuture: const Duration(seconds: 30));

    final inline = await WatchdogTask(h.runtime, clock: h.clock.call)
        .run(trigger: 'watchdog');

    expect(inline, isFalse);
    expect(h.bridge.serviceStartRequests, 1);
    expect(h.bridge.serviceRunning, isTrue);
    // Nothing was processed here; the service takes over.
    expect(h.youtube.calls, isEmpty);
  });

  test('service already running: leaves it alone', () async {
    final h = EngineHarness();
    h.bridge.serviceRunning = true;
    await h.addUpload();

    await WatchdogTask(h.runtime, clock: h.clock.call).run(trigger: 'wakeup');

    expect(h.bridge.serviceStartRequests, 0);
    expect(h.youtube.calls, isEmpty);
  });

  test('service cannot start: processes due uploads inline', () async {
    final h = EngineHarness();
    h.bridge.canStartService = false;
    final created = await h.addUpload();

    final inline = await WatchdogTask(h.runtime, clock: h.clock.call)
        .run(trigger: 'wakeup');

    expect(inline, isTrue);
    expect(h.bridge.serviceStartRequests, 1);
    final upload = (await h.repository.getById(created.id!))!;
    expect(upload.status, UploadStatus.completed);
    expect(h.notifier.events, ['starting:${created.id}', 'completed:${created.id}']);
    // Queue is empty afterwards → alarm cleared.
    expect(h.bridge.scheduledWakeup, isNull);
  });

  test('an interrupted upload makes the watchdog start the service', () async {
    // The service resumes it on start-up (with the foreground time budget).
    final h = EngineHarness(now: DateTime.now());
    final created = await h.addUpload();
    await h.repository.updateStatus(created.id!, status: UploadStatus.uploading);
    h.clock.advance(const Duration(hours: 1));

    final inline = await WatchdogTask(h.runtime, clock: h.clock.call)
        .run(trigger: 'watchdog');

    expect(inline, isFalse);
    expect(h.bridge.serviceStartRequests, 1);
    expect(
      (await h.repository.getById(created.id!))!.status,
      UploadStatus.uploading,
      reason: 'left for the service to resume',
    );
    expect(h.youtube.calls, isEmpty);
  });

  test('resumes interrupted uploads inline when the service cannot start',
      () async {
    final h = EngineHarness(now: DateTime.now());
    h.bridge.canStartService = false;
    final created = await h.addUpload();
    await h.repository.updateStatus(
      created.id!,
      status: UploadStatus.uploading,
      youtubeStatus: PlatformUploadStatus.uploading,
    );
    h.clock.advance(const Duration(hours: 1));

    final inline = await WatchdogTask(h.runtime, clock: h.clock.call)
        .run(trigger: 'watchdog');

    expect(inline, isTrue);
    final upload = (await h.repository.getById(created.id!))!;
    expect(upload.status, UploadStatus.completed);
    expect(upload.retryCount, 1);
    expect(h.youtube.calls, hasLength(1));
  });

  test('answers pending WhatsApp "Status" messages on the way', () async {
    final requests = <http.Request>[];
    final settings = SettingsService(
      store: InMemoryKeyValueStore(),
      buildDefaults: const AppSettings(
        whatsappEndpoint: 'https://agent.example.com',
        whatsappRecipient: '923001234567',
      ),
    );
    final inbox = WhatsAppInboxService(
      settingsService: settings,
      repository: InMemoryScheduleRepository(),
      client: WhatsAppHttpClient(
        client: MockClient((request) async {
          requests.add(request);
          if (request.method == 'GET') {
            return http.Response(
              jsonEncode([
                {'id': '1', 'from': '923001234567', 'text': 'Status'},
              ]),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      ),
      cursorStore: InMemoryInboxCursorStore(),
      lock: InMemoryInboxLock(),
    );
    final h = EngineHarness(inbox: inbox);

    await WatchdogTask(h.runtime, clock: h.clock.call).run(trigger: 'watchdog');

    final post = requests.singleWhere((r) => r.method == 'POST');
    final body = jsonDecode(post.body) as Map<String, dynamic>;
    expect(body['event'], 'status_reply');
    expect(body['text'], 'No uploads scheduled.');
    expect(h.statusStore.status?.lastWatchdogRun, h.clock.now);
  });
}
