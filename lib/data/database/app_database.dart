import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../core/constants.dart';
import '../models/scheduled_upload.dart';
import '../models/upload_event.dart';

/// Owns the single SQLite connection used by the app.
///
/// * On the device the default [databaseFactory] (sqflite) is used and the
///   file lives in the platform's databases directory.
/// * Tests inject `databaseFactoryFfi` + [inMemoryDatabasePath].
/// * Phase 2's background isolate creates its own instance – SQLite handles
///   the cross-isolate locking.
class AppDatabase {
  AppDatabase({String? path, DatabaseFactory? factory})
    : _path = path,
      _factory = factory;

  final String? _path;
  final DatabaseFactory? _factory;

  Database? _database;
  Future<Database>? _opening;

  /// Lazily opens (once) and returns the database. Concurrent callers share
  /// the same pending open; a failed open can be retried on the next call.
  Future<Database> get database async {
    final existing = _database;
    if (existing != null && existing.isOpen) return existing;
    final pending = _opening;
    if (pending != null) return pending;

    final future = _open();
    _opening = future;
    try {
      final db = await future;
      _database = db;
      return db;
    } finally {
      _opening = null;
    }
  }

  DatabaseFactory get _resolvedFactory => _factory ?? databaseFactory;

  Future<String> resolvePath() async {
    if (_path != null) return _path;
    final directory = await _resolvedFactory.getDatabasesPath();
    return p.join(directory, AppConstants.databaseName);
  }

  Future<Database> _open() async {
    final path = await resolvePath();
    return _resolvedFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: AppConstants.databaseVersion,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
  }

  Future<void> close() async {
    final db = _database;
    _database = null;
    _opening = null;
    if (db != null && db.isOpen) await db.close();
  }

  // --- Schema ----------------------------------------------------------------

  static const String _createUploadsTable =
      '''
CREATE TABLE ${UploadColumns.table} (
  ${UploadColumns.id} INTEGER PRIMARY KEY AUTOINCREMENT,
  ${UploadColumns.videoPath} TEXT NOT NULL,
  ${UploadColumns.videoName} TEXT NOT NULL,
  ${UploadColumns.videoSizeBytes} INTEGER NOT NULL DEFAULT 0,
  ${UploadColumns.title} TEXT NOT NULL,
  ${UploadColumns.description} TEXT NOT NULL DEFAULT '',
  ${UploadColumns.tags} TEXT NOT NULL DEFAULT '',
  ${UploadColumns.scheduledTime} INTEGER NOT NULL,
  ${UploadColumns.status} TEXT NOT NULL DEFAULT 'scheduled',
  ${UploadColumns.platform} TEXT NOT NULL DEFAULT 'both',
  ${UploadColumns.youtubeStatus} TEXT NOT NULL DEFAULT 'pending',
  ${UploadColumns.instagramStatus} TEXT NOT NULL DEFAULT 'pending',
  ${UploadColumns.youtubeVideoId} TEXT,
  ${UploadColumns.instagramMediaId} TEXT,
  ${UploadColumns.uploadProgress} REAL NOT NULL DEFAULT 0,
  ${UploadColumns.errorMessage} TEXT,
  ${UploadColumns.retryCount} INTEGER NOT NULL DEFAULT 0,
  ${UploadColumns.createdAt} INTEGER NOT NULL,
  ${UploadColumns.updatedAt} INTEGER NOT NULL
)''';

  static const String _createEventsTable =
      '''
CREATE TABLE ${EventColumns.table} (
  ${EventColumns.id} INTEGER PRIMARY KEY AUTOINCREMENT,
  ${EventColumns.uploadId} INTEGER NOT NULL
    REFERENCES ${UploadColumns.table}(${UploadColumns.id}) ON DELETE CASCADE,
  ${EventColumns.timestamp} INTEGER NOT NULL,
  ${EventColumns.level} TEXT NOT NULL DEFAULT 'info',
  ${EventColumns.message} TEXT NOT NULL
)''';

  static const List<String> _createIndexes = [
    'CREATE INDEX idx_uploads_scheduled_time '
        'ON ${UploadColumns.table}(${UploadColumns.scheduledTime})',
    'CREATE INDEX idx_uploads_status '
        'ON ${UploadColumns.table}(${UploadColumns.status})',
    'CREATE INDEX idx_events_upload_id '
        'ON ${EventColumns.table}(${EventColumns.uploadId})',
  ];

  Future<void> _onCreate(Database db, int version) async {
    final batch = db.batch();
    batch.execute(_createUploadsTable);
    batch.execute(_createEventsTable);
    for (final statement in _createIndexes) {
      batch.execute(statement);
    }
    await batch.commit(noResult: true);
  }

  /// Incremental migrations. Add an entry for every new
  /// [AppConstants.databaseVersion]; each list runs inside the upgrade.
  static const Map<int, List<String>> _migrations = {
    // 2: ['ALTER TABLE scheduled_uploads ADD COLUMN example TEXT'],
  };

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    final batch = db.batch();
    for (var version = oldVersion + 1; version <= newVersion; version++) {
      for (final statement in _migrations[version] ?? const <String>[]) {
        batch.execute(statement);
      }
    }
    await batch.commit(noResult: true);
  }
}
