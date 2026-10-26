import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Where polling left off, plus a little diagnostics for the Settings screen.
@immutable
class InboxCursor {
  const InboxCursor({
    this.lastTimestamp,
    this.handledIds = const [],
    this.lastCheckedAt,
    this.lastError,
    this.lastReplyAt,
    this.lastReplyPreview,
    this.replyCount = 0,
  });

  factory InboxCursor.fromMap(Map<Object?, Object?> map) {
    DateTime? date(Object? raw) => raw is num
        ? DateTime.fromMillisecondsSinceEpoch(raw.toInt())
        : null;
    final ids = map['handledIds'];
    return InboxCursor(
      lastTimestamp: date(map['lastTimestamp']),
      handledIds: ids is List ? ids.map((e) => '$e').toList() : const [],
      lastCheckedAt: date(map['lastCheckedAt']),
      lastError: map['lastError'] as String?,
      lastReplyAt: date(map['lastReplyAt']),
      lastReplyPreview: map['lastReplyPreview'] as String?,
      replyCount: (map['replyCount'] as num?)?.toInt() ?? 0,
    );
  }

  /// Newest message timestamp seen so far (sent to the agent as `since`).
  final DateTime? lastTimestamp;

  /// Recently answered / seen message ids (bounded), newest last.
  final List<String> handledIds;

  final DateTime? lastCheckedAt;
  final String? lastError;
  final DateTime? lastReplyAt;
  final String? lastReplyPreview;
  final int replyCount;

  static const int maxHandledIds = 300;

  bool isHandled(String id) => handledIds.contains(id);

  InboxCursor copyWith({
    DateTime? lastTimestamp,
    List<String>? handledIds,
    DateTime? lastCheckedAt,
    Object? lastError = _unset,
    DateTime? lastReplyAt,
    String? lastReplyPreview,
    int? replyCount,
  }) => InboxCursor(
    lastTimestamp: lastTimestamp ?? this.lastTimestamp,
    handledIds: _bounded(handledIds ?? this.handledIds),
    lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
    lastError: identical(lastError, _unset)
        ? this.lastError
        : lastError as String?,
    lastReplyAt: lastReplyAt ?? this.lastReplyAt,
    lastReplyPreview: lastReplyPreview ?? this.lastReplyPreview,
    replyCount: replyCount ?? this.replyCount,
  );

  static const Object _unset = Object();

  static List<String> _bounded(List<String> ids) => ids.length <= maxHandledIds
      ? List.unmodifiable(ids)
      : List.unmodifiable(ids.sublist(ids.length - maxHandledIds));

  Map<String, Object?> toMap() => {
    'lastTimestamp': lastTimestamp?.millisecondsSinceEpoch,
    'handledIds': handledIds,
    'lastCheckedAt': lastCheckedAt?.millisecondsSinceEpoch,
    'lastError': lastError,
    'lastReplyAt': lastReplyAt?.millisecondsSinceEpoch,
    'lastReplyPreview': lastReplyPreview,
    'replyCount': replyCount,
  };
}

abstract interface class InboxCursorStore {
  Future<InboxCursor> read();
  Future<void> write(InboxCursor cursor);
}

/// JSON file in the app support directory (shared by all isolates).
class FileInboxCursorStore implements InboxCursorStore {
  FileInboxCursorStore({Directory? directoryOverride})
    : _directoryOverride = directoryOverride;

  final Directory? _directoryOverride;

  static const String fileName = 'whatsapp_inbox.json';

  Future<File> _file() async {
    final directory =
        _directoryOverride ?? await getApplicationSupportDirectory();
    return File(p.join(directory.path, fileName));
  }

  @override
  Future<InboxCursor> read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const InboxCursor();
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return const InboxCursor();
      return InboxCursor.fromMap(raw.cast<Object?, Object?>());
    } catch (e) {
      debugPrint('Could not read the WhatsApp inbox cursor: $e');
      return const InboxCursor();
    }
  }

  @override
  Future<void> write(InboxCursor cursor) async {
    try {
      final file = await _file();
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(cursor.toMap()), flush: true);
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint('Could not write the WhatsApp inbox cursor: $e');
    }
  }
}

class InMemoryInboxCursorStore implements InboxCursorStore {
  InboxCursor cursor = const InboxCursor();

  @override
  Future<InboxCursor> read() async => cursor;

  @override
  Future<void> write(InboxCursor value) async {
    cursor = value;
  }
}

/// Serialises inbox polls across isolates/processes so a "Status" message is
/// never answered twice (UI isolate, foreground service and WorkManager can
/// all poll).
abstract interface class InboxLock {
  /// Runs [action] while holding the lock; returns `null` without running it
  /// when somebody else holds the lock right now.
  Future<T?> tryRun<T>(Future<T> Function() action);
}

/// Lock file created with `O_EXCL` in the app support directory.
///
/// Dart's `RandomAccessFile.lock` is a POSIX record lock, which is owned by
/// the *process* — isolates of the same app would not exclude each other.
/// Atomic exclusive creation works across isolates and processes alike. A
/// lock older than [staleAfter] is treated as left behind by a crash.
class FileInboxLock implements InboxLock {
  FileInboxLock({
    Directory? directoryOverride,
    this.staleAfter = const Duration(minutes: 2),
  }) : _directoryOverride = directoryOverride;

  final Directory? _directoryOverride;
  final Duration staleAfter;

  static const String fileName = 'whatsapp_inbox.lock';

  @override
  Future<T?> tryRun<T>(Future<T> Function() action) async {
    final directory =
        _directoryOverride ?? await getApplicationSupportDirectory();
    final file = File(p.join(directory.path, fileName));
    if (!await _acquire(file)) return null;
    try {
      return await action();
    } finally {
      try {
        await file.delete();
      } catch (_) {
        // Nothing to release.
      }
    }
  }

  Future<bool> _acquire(File file) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await file.create(exclusive: true);
        await file.writeAsString('${DateTime.now().toIso8601String()} $pid');
        return true;
      } on FileSystemException {
        // Somebody holds it — unless it is stale.
        try {
          final age = DateTime.now().difference(await file.lastModified());
          if (age > staleAfter) {
            await file.delete();
            continue;
          }
        } catch (_) {
          // Vanished in between: retry once.
          continue;
        }
        return false;
      }
    }
    return false;
  }
}

/// In-process lock for tests and the UI isolate fallback.
class InMemoryInboxLock implements InboxLock {
  bool _held = false;
  int skipped = 0;

  @override
  Future<T?> tryRun<T>(Future<T> Function() action) async {
    if (_held) {
      skipped++;
      return null;
    }
    _held = true;
    try {
      return await action();
    } finally {
      _held = false;
    }
  }
}
