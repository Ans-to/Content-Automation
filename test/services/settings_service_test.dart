import 'package:content_automation/core/env.dart';
import 'package:content_automation/services/secure_key_value_store.dart';
import 'package:content_automation/services/settings_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Env', () {
    test('placeholders are detected', () {
      expect(Env.isPlaceholder('YOUR_YOUTUBE_CLIENT_ID'), isTrue);
      expect(Env.isPlaceholder(''), isTrue);
      expect(Env.isPlaceholder('   '), isTrue);
      expect(Env.isPlaceholder(null), isTrue);
      expect(Env.isPlaceholder('123-abc.apps.googleusercontent.com'), isFalse);
      expect(Env.valueOrNull(' real '), 'real');
      expect(Env.valueOrNull('YOUR_X'), isNull);
    });

    test('defaults compile to placeholders when no dart-defines are given', () {
      // When built without --dart-define-from-file every value is a placeholder.
      expect(Env.isPlaceholder(Env.youtubeClientId), isTrue);
      expect(Env.isPlaceholder(Env.instagramAccessToken), isTrue);
      expect(Env.isPlaceholder(Env.whatsappAgentEndpoint), isTrue);
      expect(Env.isPlaceholder(Env.ngrokAuthToken), isTrue);
    });
  });

  group('AppSettings', () {
    test('configured flags', () {
      const empty = AppSettings();
      expect(empty.isYouTubeConfigured, isFalse);
      expect(empty.isInstagramConfigured, isFalse);
      expect(empty.isWhatsAppConfigured, isFalse);
      expect(empty.isEmpty, isTrue);

      const full = AppSettings(
        youtubeClientId: 'cid',
        instagramAccessToken: 'tok',
        instagramBusinessAccountId: '178',
        whatsappEndpoint: 'https://a.example',
        whatsappApiKey: 'k',
      );
      expect(full.isYouTubeConfigured, isTrue);
      expect(full.isInstagramConfigured, isTrue);
      expect(full.isWhatsAppConfigured, isTrue);
      expect(full.isTunnelConfigured, isFalse);
    });

    test('fillMissingFrom never overwrites existing values', () {
      const stored = AppSettings(youtubeClientId: 'mine');
      const defaults = AppSettings(
        youtubeClientId: 'theirs',
        youtubeApiKey: 'seeded-key',
      );
      final merged = stored.fillMissingFrom(defaults);
      expect(merged.youtubeClientId, 'mine');
      expect(merged.youtubeApiKey, 'seeded-key');
    });

    test('equality is value based', () {
      expect(const AppSettings(youtubeApiKey: 'a'), const AppSettings(youtubeApiKey: 'a'));
      expect(const AppSettings(youtubeApiKey: 'a'), isNot(const AppSettings()));
    });
  });

  group('SettingsService', () {
    late InMemoryKeyValueStore store;
    late SettingsService service;

    setUp(() {
      store = InMemoryKeyValueStore();
      service = SettingsService(store: store, buildDefaults: const AppSettings());
    });

    test('load on a fresh device returns empty settings', () async {
      final settings = await service.load();
      expect(settings.isEmpty, isTrue);
      expect(await store.readAll(), isEmpty);
    });

    test('save then load round-trips and trims values', () async {
      await service.save(
        const AppSettings(
          youtubeClientId: ' cid ',
          whatsappEndpoint: 'https://agent.example.com',
          whatsappApiKey: 'secret',
        ),
      );
      expect(await store.read(SettingsKeys.youtubeClientId), 'cid');
      expect(await store.read(SettingsKeys.youtubeApiKey), isNull);

      final loaded = await service.load();
      expect(loaded.youtubeClientId, 'cid');
      expect(loaded.whatsappEndpoint, 'https://agent.example.com');
      expect(loaded.isWhatsAppConfigured, isTrue);
    });

    test('emptying a field removes it from storage', () async {
      await service.save(const AppSettings(youtubeApiKey: 'k'));
      await service.save(const AppSettings());
      expect(await store.read(SettingsKeys.youtubeApiKey), isNull);
    });

    test('build-time defaults seed only empty fields and are persisted', () async {
      await store.write(SettingsKeys.instagramAppId, 'user-value');
      final seededService = SettingsService(
        store: store,
        buildDefaults: const AppSettings(
          instagramAppId: 'env-value',
          ngrokAuthToken: 'env-token',
        ),
      );
      final settings = await seededService.load();
      expect(settings.instagramAppId, 'user-value');
      expect(settings.ngrokAuthToken, 'env-token');
      expect(await store.read(SettingsKeys.ngrokAuthToken), 'env-token');
    });

    test('clear removes every key', () async {
      await service.save(const AppSettings(youtubeApiKey: 'k', whatsappApiKey: 'w'));
      await service.clear();
      expect(await store.readAll(), isEmpty);
    });
  });
}
