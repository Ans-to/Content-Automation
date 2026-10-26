import 'package:content_automation/integrations/youtube/google_auth_gateway.dart';
import 'package:content_automation/integrations/youtube/youtube_account_service.dart';
import 'package:content_automation/services/secure_key_value_store.dart';
import 'package:content_automation/services/settings_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_youtube_server.dart';

void main() {
  late InMemoryKeyValueStore store;
  late SettingsService settings;
  late InMemoryGoogleAuthGateway auth;
  late FakeYouTubeServer server;

  YouTubeAccountService service() => YouTubeAccountService(
    auth: auth,
    settingsService: settings,
    client: server.client,
    apiRootUrl: server.apiRootUrl,
  );

  setUp(() async {
    store = InMemoryKeyValueStore();
    settings = SettingsService(store: store, buildDefaults: const AppSettings());
    await settings.save(const AppSettings(youtubeClientId: 'web-id'));
    auth = InMemoryGoogleAuthGateway(
      account: const GoogleAccountInfo(
        email: 'creator@example.com',
        displayName: 'Creator',
        accessToken: 't1',
      ),
    );
    server = FakeYouTubeServer();
  });

  test('signIn stores the account and the channel title', () async {
    final account = await service().signIn();

    expect(account.email, 'creator@example.com');
    expect(account.channelTitle, 'Fake Channel');
    expect(auth.initializedWith, 'web-id');
    expect(auth.scopeRequests.single, YouTubeScopes.all);

    final stored = await settings.load();
    expect(stored.youtubeAccountEmail, 'creator@example.com');
    expect(stored.youtubeChannelTitle, 'Fake Channel');
    expect(stored.youtubeClientId, 'web-id');
    expect(stored.isYouTubeConfigured, isTrue);

    final channels = server.requests.single;
    expect(channels.url.path, endsWith('/youtube/v3/channels'));
    expect(channels.url.queryParameters['mine'], 'true');
    expect(channels.headers['Authorization'], 'Bearer t1');
  });

  test('a failing channel lookup does not block sign-in', () async {
    server.faults[0] = FakeYouTubeServer.googleError(
      403,
      'no channel',
      reason: 'youtubeSignupRequired',
    );
    final account = await service().signIn();
    expect(account.channelTitle, '');
    expect((await settings.load()).youtubeAccountEmail, 'creator@example.com');
  });

  test('signIn requires the client ID', () async {
    await settings.save(const AppSettings());
    await expectLater(
      service().signIn(),
      throwsA(isA<GoogleAuthException>()),
    );
    expect((await settings.load()).isYouTubeSignedIn, isFalse);
  });

  test('cancelled sign-in propagates with the cancelled flag', () async {
    auth.signInError = const GoogleAuthException('Sign-in was cancelled.', cancelled: true);
    await expectLater(
      service().signIn(),
      throwsA(
        isA<GoogleAuthException>().having((e) => e.cancelled, 'cancelled', true),
      ),
    );
  });

  test('signOut clears the account but keeps the client ID', () async {
    await service().signIn();
    await service().signOut();

    expect(auth.signedOut, isTrue);
    final stored = await settings.load();
    expect(stored.youtubeAccountEmail, '');
    expect(stored.youtubeChannelTitle, '');
    expect(stored.youtubeClientId, 'web-id');
  });
}
