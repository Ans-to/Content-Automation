import 'dart:convert';

import 'package:content_automation/data/models/enums.dart';
import 'package:content_automation/data/models/scheduled_upload.dart';
import 'package:content_automation/integrations/whatsapp/whatsapp_agent.dart';
import 'package:content_automation/integrations/whatsapp/whatsapp_client.dart';
import 'package:content_automation/services/secure_key_value_store.dart';
import 'package:content_automation/services/settings_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const config = WhatsAppAgentConfig(
    endpoint: 'https://agent.example.com/api',
    apiKey: 'secret-key',
    recipient: '923001234567',
  );

  group('WhatsAppAgentConfig', () {
    test('derives send/inbox URLs from the endpoint', () {
      expect(config.isConfigured, isTrue);
      expect(config.flavor, WhatsAppAgentFlavor.generic);
      expect(config.sendUri.toString(), 'https://agent.example.com/api/messages');
      expect(
        config.inboxUri.toString(),
        'https://agent.example.com/api/messages',
      );
      expect(config.supportsInbox, isTrue);
      expect(config.recipientDigits, '923001234567');
    });

    test('does not double the /messages suffix', () {
      const withSuffix = WhatsAppAgentConfig(
        endpoint: 'https://agent.example.com/api/messages/',
        recipient: '1',
      );
      expect(
        withSuffix.sendUri.toString(),
        'https://agent.example.com/api/messages',
      );
    });

    test('uses the explicit inbox URL when set', () {
      const custom = WhatsAppAgentConfig(
        endpoint: 'https://agent.example.com/send',
        recipient: '1',
        inboxUrl: 'https://other.example.com/inbox?token=x',
      );
      expect(custom.sendUri.toString(), 'https://agent.example.com/send/messages');
      expect(custom.inboxUri.toString(), 'https://other.example.com/inbox?token=x');
    });

    test('detects the Cloud API (outbound only)', () {
      const cloud = WhatsAppAgentConfig(
        endpoint: 'https://graph.facebook.com/v21.0/123456/messages',
        apiKey: 'EAAG…',
        recipient: '923001234567',
      );
      expect(cloud.flavor, WhatsAppAgentFlavor.cloudApi);
      expect(
        cloud.sendUri.toString(),
        'https://graph.facebook.com/v21.0/123456/messages',
      );
      expect(cloud.supportsInbox, isFalse);
    });

    test('is not configured without an http(s) endpoint or recipient', () {
      expect(
        const WhatsAppAgentConfig(endpoint: 'agent', recipient: '1').isConfigured,
        isFalse,
      );
      expect(
        const WhatsAppAgentConfig(endpoint: 'https://a.b').isConfigured,
        isFalse,
      );
      expect(
        () => const WhatsAppAgentConfig(endpoint: '').sendUri,
        throwsA(isA<WhatsAppAgentException>()),
      );
    });
  });

  group('WhatsAppHttpClient.sendText', () {
    test('posts the generic JSON contract with auth headers', () async {
      http.Request? seen;
      final client = WhatsAppHttpClient(
        client: MockClient((request) async {
          seen = request;
          return http.Response('{"ok":true}', 200);
        }),
        clock: () => DateTime.utc(2026, 10, 26, 12),
      );
      final upload = ScheduledUpload(
        id: 9,
        videoPath: '/v.mp4',
        videoName: 'v.mp4',
        title: 'Teaser',
        scheduledTime: DateTime.utc(2026, 10, 26, 13),
        platform: UploadPlatform.youtube,
        instagramStatus: PlatformUploadStatus.notApplicable,
      );

      await client.sendText(
        config,
        'Time reached. Starting upload for Teaser.',
        event: 'upload_started',
        upload: upload,
      );

      expect(seen, isNotNull);
      expect(seen!.method, 'POST');
      expect(seen!.url.toString(), 'https://agent.example.com/api/messages');
      expect(seen!.headers['Authorization'], 'Bearer secret-key');
      expect(seen!.headers['X-API-Key'], 'secret-key');
      expect(seen!.headers['Content-Type'], startsWith('application/json'));
      final body = jsonDecode(seen!.body) as Map<String, dynamic>;
      expect(body['to'], '923001234567');
      expect(body['type'], 'text');
      expect(body['text'], 'Time reached. Starting upload for Teaser.');
      expect(body['message'], body['text']);
      expect(body['event'], 'upload_started');
      expect(body['sent_at'], '2026-10-26T12:00:00.000Z');
      final uploadJson = body['upload'] as Map<String, dynamic>;
      expect(uploadJson['id'], 9);
      expect(uploadJson['title'], 'Teaser');
      expect(uploadJson['platform'], 'youtube');
      expect(uploadJson['youtube_status'], 'pending');
      expect(uploadJson['instagram_status'], 'n/a');
    });

    test('speaks the Cloud API format when pointed at graph.facebook.com',
        () async {
      http.Request? seen;
      final client = WhatsAppHttpClient(
        client: MockClient((request) async {
          seen = request;
          return http.Response('{"messages":[{"id":"wamid.X"}]}', 200);
        }),
      );
      const cloud = WhatsAppAgentConfig(
        endpoint: 'https://graph.facebook.com/v21.0/123/messages',
        apiKey: 'token',
        recipient: '923001234567',
      );
      await client.sendText(cloud, 'hi');
      final body = jsonDecode(seen!.body) as Map<String, dynamic>;
      expect(body['messaging_product'], 'whatsapp');
      expect(body['to'], '923001234567');
      expect(body['text'], {'preview_url': false, 'body': 'hi'});
      expect(body.containsKey('event'), isFalse);
      expect(seen!.headers['Authorization'], 'Bearer token');
    });

    test('omits auth headers without an API key and honours `to`', () async {
      http.Request? seen;
      final client = WhatsAppHttpClient(
        client: MockClient((request) async {
          seen = request;
          return http.Response('', 204);
        }),
      );
      await client.sendText(
        const WhatsAppAgentConfig(
          endpoint: 'http://10.0.0.5:3000',
          recipient: '1',
        ),
        'reply',
        to: '923009999999',
        event: 'status_reply',
      );
      expect(seen!.url.toString(), 'http://10.0.0.5:3000/messages');
      expect(seen!.headers.containsKey('Authorization'), isFalse);
      expect(jsonDecode(seen!.body)['to'], '923009999999');
    });

    test('maps HTTP errors to readable exceptions', () async {
      final client = WhatsAppHttpClient(
        client: MockClient(
          (_) async => http.Response('{"error":"bad token"}', 401),
        ),
      );
      await expectLater(
        () => client.sendText(config, 'x'),
        throwsA(
          isA<WhatsAppAgentException>()
              .having((e) => e.statusCode, 'statusCode', 401)
              .having((e) => e.message, 'message', contains('HTTP 401'))
              .having((e) => e.message, 'message', contains('bad token'))
              .having((e) => e.message, 'message', contains('API key')),
        ),
      );
    });

    test('wraps transport failures', () async {
      final client = WhatsAppHttpClient(
        client: MockClient((_) async => throw http.ClientException('refused')),
      );
      await expectLater(
        () => client.sendText(config, 'x'),
        throwsA(
          isA<WhatsAppAgentException>().having(
            (e) => e.message,
            'message',
            contains('Could not reach'),
          ),
        ),
      );
    });

    test('refuses to send without a recipient', () async {
      final client = WhatsAppHttpClient(
        client: MockClient((_) async => http.Response('', 200)),
      );
      await expectLater(
        () => client.sendText(
          const WhatsAppAgentConfig(endpoint: 'https://a.example.com'),
          'x',
        ),
        throwsA(isA<WhatsAppAgentException>()),
      );
    });
  });

  group('WhatsAppHttpClient.fetchInbox', () {
    test('GETs with since/limit/from and parses the messages', () async {
      http.Request? seen;
      final client = WhatsAppHttpClient(
        client: MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode({
              'messages': [
                {
                  'id': 'm1',
                  'from': '923001234567',
                  'text': 'Status',
                  'timestamp': '2026-10-26T10:00:00Z',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final messages = await client.fetchInbox(
        config,
        since: DateTime.utc(2026, 10, 26, 9, 50),
        limit: 20,
      );
      expect(seen!.method, 'GET');
      expect(seen!.url.path, '/api/messages');
      expect(seen!.url.queryParameters, {
        'since': '2026-10-26T09:50:00.000Z',
        'limit': '20',
        'from': '923001234567',
      });
      expect(seen!.headers['X-API-Key'], 'secret-key');
      expect(messages.single.id, 'm1');
      expect(messages.single.text, 'Status');
    });

    test('keeps existing query parameters of a custom inbox URL', () async {
      http.Request? seen;
      final client = WhatsAppHttpClient(
        client: MockClient((request) async {
          seen = request;
          return http.Response('[]', 200);
        }),
      );
      const custom = WhatsAppAgentConfig(
        endpoint: 'https://agent.example.com',
        recipient: '1',
        inboxUrl: 'https://agent.example.com/inbox?token=abc',
      );
      expect(await client.fetchInbox(custom), isEmpty);
      expect(seen!.url.queryParameters['token'], 'abc');
      expect(seen!.url.queryParameters['limit'], '50');
    });

    test('rejects invalid JSON and non-2xx answers', () async {
      final bad = WhatsAppHttpClient(
        client: MockClient((_) async => http.Response('<html>', 200)),
      );
      await expectLater(
        () => bad.fetchInbox(config),
        throwsA(
          isA<WhatsAppAgentException>().having(
            (e) => e.message,
            'message',
            contains('not valid JSON'),
          ),
        ),
      );
      final missing = WhatsAppHttpClient(
        client: MockClient((_) async => http.Response('nope', 404)),
      );
      await expectLater(
        () => missing.fetchInbox(config),
        throwsA(
          isA<WhatsAppAgentException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.message, 'message', contains('endpoint URL')),
        ),
      );
    });

    test('throws when the configuration has no inbox', () async {
      final client = WhatsAppHttpClient(
        client: MockClient((_) async => http.Response('[]', 200)),
      );
      const cloud = WhatsAppAgentConfig(
        endpoint: 'https://graph.facebook.com/v21.0/1/messages',
        recipient: '1',
      );
      await expectLater(
        () => client.fetchInbox(cloud),
        throwsA(isA<WhatsAppAgentException>()),
      );
    });
  });

  group('HttpWhatsAppAgent', () {
    late InMemoryKeyValueStore store;
    late SettingsService settings;
    late List<http.Request> requests;
    late HttpWhatsAppAgent agent;

    setUp(() {
      store = InMemoryKeyValueStore();
      settings = SettingsService(
        store: store,
        buildDefaults: const AppSettings(),
      );
      requests = [];
      agent = HttpWhatsAppAgent(
        settingsService: settings,
        client: WhatsAppHttpClient(
          client: MockClient((request) async {
            requests.add(request);
            return http.Response('{"ok":true}', 200);
          }),
        ),
      );
    });

    test('reports not configured until endpoint + number are saved', () async {
      expect(await agent.isConfigured(), isFalse);
      await settings.save(
        const AppSettings(
          whatsappEndpoint: 'https://agent.example.com',
          whatsappRecipient: '923001234567',
        ),
      );
      expect(await agent.isConfigured(), isTrue);
    });

    test('sends the three lifecycle messages with event tags', () async {
      await settings.save(
        const AppSettings(
          whatsappEndpoint: 'https://agent.example.com',
          whatsappApiKey: 'k',
          whatsappRecipient: '923001234567',
        ),
      );
      final upload = ScheduledUpload(
        id: 1,
        videoPath: '/v.mp4',
        videoName: 'v.mp4',
        title: 'Clip',
        scheduledTime: DateTime(2026, 10, 26, 18),
      );
      await agent.notifyUploadStarting(upload);
      await agent.notifyUploadFailed(upload, 'disk full');
      await agent.notifyUploadCompleted(upload);

      final bodies = requests
          .map((r) => jsonDecode(r.body) as Map<String, dynamic>)
          .toList();
      expect(bodies.map((b) => b['event']), [
        'upload_started',
        'upload_failed',
        'upload_completed',
      ]);
      expect(bodies[0]['text'], 'Time reached. Starting upload for Clip.');
      expect(bodies[1]['text'], contains('Reason: disk full'));
      expect(bodies[2]['text'], startsWith('Upload completed for Clip.'));
      expect(requests.every((r) => r.headers['X-API-Key'] == 'k'), isTrue);
    });

    test('sendTestMessage refuses to run unconfigured', () async {
      await expectLater(
        agent.sendTestMessage,
        throwsA(isA<WhatsAppAgentException>()),
      );
      expect(requests, isEmpty);

      await settings.save(
        const AppSettings(
          whatsappEndpoint: 'https://agent.example.com',
          whatsappRecipient: '923001234567',
        ),
      );
      final text = await agent.sendTestMessage(now: DateTime(2026, 10, 26, 9));
      expect(text, contains('test message'));
      expect(jsonDecode(requests.single.body)['event'], 'test');
    });
  });
}
