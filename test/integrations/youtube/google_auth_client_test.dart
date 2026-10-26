import 'package:content_automation/integrations/youtube/google_auth_client.dart';
import 'package:content_automation/integrations/youtube/google_auth_gateway.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('GatewayTokenSource', () {
    test('caches the token and refreshes after the ttl', () async {
      var now = DateTime(2026, 10, 26, 18);
      final gateway = InMemoryGoogleAuthGateway()..authorized = true;
      final source = GatewayTokenSource(
        gateway: gateway,
        email: 'creator@example.com',
        ttl: const Duration(minutes: 40),
        clock: () => now,
      );

      expect(await source.token(), 'token-1');
      expect(await source.token(), 'token-1');
      expect(gateway.tokenRequests, 1);

      now = now.add(const Duration(minutes: 41));
      // The cached token is still "valid" for the gateway, so it is reused.
      expect(await source.token(), 'token-1');
      expect(gateway.tokenRequests, 2);
    });

    test('forceRefresh invalidates the old token first', () async {
      final gateway = InMemoryGoogleAuthGateway()..authorized = true;
      final source = GatewayTokenSource(
        gateway: gateway,
        email: 'creator@example.com',
      );
      expect(await source.token(), 'token-1');
      expect(await source.token(forceRefresh: true), 'token-2');
      expect(gateway.invalidated, {'token-1'});
    });

    test('throws a user-facing error when no token is available', () async {
      final gateway = InMemoryGoogleAuthGateway(); // not authorized
      final source = GatewayTokenSource(
        gateway: gateway,
        email: 'creator@example.com',
      );
      await expectLater(
        source.token(),
        throwsA(
          isA<MissingAuthorizationException>().having(
            (e) => e.message,
            'message',
            contains('Settings → YouTube'),
          ),
        ),
      );
    });

    test('a different stored e-mail yields no token', () async {
      final gateway = InMemoryGoogleAuthGateway()..authorized = true;
      final source = GatewayTokenSource(
        gateway: gateway,
        email: 'someone-else@example.com',
      );
      await expectLater(
        source.token(),
        throwsA(isA<MissingAuthorizationException>()),
      );
    });
  });

  group('GoogleAuthClient', () {
    test('adds the bearer header', () async {
      final gateway = InMemoryGoogleAuthGateway()..authorized = true;
      final requests = <http.Request>[];
      final client = GoogleAuthClient(
        MockClient((request) async {
          requests.add(request);
          return http.Response('ok', 200);
        }),
        GatewayTokenSource(gateway: gateway, email: 'creator@example.com'),
      );

      final response = await client.get(Uri.parse('https://api.example/x'));
      expect(response.statusCode, 200);
      expect(requests.single.headers['Authorization'], 'Bearer token-1');
    });

    test('retries once with a fresh token after a 401', () async {
      final gateway = InMemoryGoogleAuthGateway()..authorized = true;
      final seen = <String?>[];
      final client = GoogleAuthClient(
        MockClient((request) async {
          seen.add(request.headers['Authorization']);
          return request.headers['Authorization'] == 'Bearer token-2'
              ? http.Response('{"ok":true}', 200)
              : http.Response('expired', 401);
        }),
        GatewayTokenSource(gateway: gateway, email: 'creator@example.com'),
      );

      final response = await client.post(
        Uri.parse('https://api.example/y'),
        body: 'payload',
      );
      expect(response.statusCode, 200);
      expect(seen, ['Bearer token-1', 'Bearer token-2']);
      expect(gateway.invalidated, {'token-1'});
    });

    test('a second 401 is returned to the caller', () async {
      final gateway = InMemoryGoogleAuthGateway()..authorized = true;
      var calls = 0;
      final client = GoogleAuthClient(
        MockClient((request) async {
          calls++;
          return http.Response('expired', 401);
        }),
        GatewayTokenSource(gateway: gateway, email: 'creator@example.com'),
      );

      final response = await client.get(Uri.parse('https://api.example/z'));
      expect(response.statusCode, 401);
      expect(calls, 2);
    });
  });
}
