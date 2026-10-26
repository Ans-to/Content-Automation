import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Minimal key/value abstraction over the device's secure storage so the
/// settings layer can be unit-tested with an in-memory implementation.
abstract interface class SecureKeyValueStore {
  Future<String?> read(String key);

  /// Writes [value]; passing `null` or an empty string removes the key.
  Future<void> write(String key, String? value);

  Future<void> delete(String key);

  Future<Map<String, String>> readAll();

  Future<void> deleteAll();
}

/// Production store backed by `flutter_secure_storage`.
///
/// On Android values are encrypted with AES-GCM using a key that lives in the
/// Android Keystore, so API keys never sit on disk in plain text and never
/// leave the device.
class FlutterSecureKeyValueStore implements SecureKeyValueStore {
  FlutterSecureKeyValueStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String? value) {
    if (value == null || value.isEmpty) return delete(key);
    return _storage.write(key: key, value: value);
  }

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<Map<String, String>> readAll() => _storage.readAll();

  @override
  Future<void> deleteAll() => _storage.deleteAll();
}

/// Non-persistent store for tests and previews.
class InMemoryKeyValueStore implements SecureKeyValueStore {
  InMemoryKeyValueStore([Map<String, String>? initial])
    : _data = {...?initial};

  final Map<String, String> _data;

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null || value.isEmpty) {
      _data.remove(key);
    } else {
      _data[key] = value;
    }
  }

  @override
  Future<void> delete(String key) async => _data.remove(key);

  @override
  Future<Map<String, String>> readAll() async => Map.unmodifiable(_data);

  @override
  Future<void> deleteAll() async => _data.clear();
}
