import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../core/constants.dart';

/// Result of copying a picked video into the app's private storage.
class PersistedVideo {
  const PersistedVideo({
    required this.path,
    required this.name,
    required this.sizeBytes,
  });

  /// Absolute path inside the app's documents directory.
  final String path;

  /// Original display name (e.g. `holiday_reel.mp4`).
  final String name;

  final int sizeBytes;
}

typedef ProgressCallback = void Function(double progress);

/// Picks videos and keeps a private copy of them until upload time.
///
/// Why copy? Android's picker hands us a temporary file in the app *cache*,
/// which the OS may purge under storage pressure. The scheduled upload might
/// be days away, so the file is moved into the app's persistent documents
/// directory instead. Nothing is uploaded or transmitted here – the video
/// stays on the device until the scheduler fires.
class VideoFileService {
  VideoFileService({Directory? storageDirectoryOverride})
    : _storageDirectoryOverride = storageDirectoryOverride;

  final Directory? _storageDirectoryOverride;
  final Uuid _uuid = const Uuid();

  /// Opens the native picker filtered to videos. Returns `null` on cancel.
  Future<PlatformFile?> pickVideo() => FilePicker.pickFile(
    dialogTitle: 'Select a video to schedule',
    type: FileType.video,
  );

  /// Best-effort removal of the picker's temporary cache files.
  Future<void> clearPickerCache() async {
    try {
      await FilePicker.clearTemporaryFiles();
    } catch (_) {
      // Not supported on every platform; ignore.
    }
  }

  /// The directory that holds all pending videos.
  Future<Directory> storageDirectory() async {
    final override = _storageDirectoryOverride;
    final Directory directory;
    if (override != null) {
      directory = override;
    } else {
      final base = await getApplicationDocumentsDirectory();
      directory = Directory(p.join(base.path, AppConstants.videoStorageFolder));
    }
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  /// Moves (or, when a move is impossible, copies) [file] into
  /// [storageDirectory]. [onProgress] receives 0..1 while copying.
  Future<PersistedVideo> persist(
    PlatformFile file, {
    ProgressCallback? onProgress,
  }) async {
    final directory = await storageDirectory();
    final extension = p.extension(file.name);
    final target = File(
      p.join(directory.path, '${_uuid.v4()}${extension.toLowerCase()}'),
    );

    final sourcePath = file.path;
    if (sourcePath != null) {
      final source = File(sourcePath);
      try {
        // Same filesystem (cache -> documents): instant, no extra disk space.
        await source.rename(target.path);
        onProgress?.call(1);
      } on FileSystemException {
        // Cross-device move: stream-copy instead, then remove the original.
        await _copyStream(
          source.openRead(),
          target,
          expectedBytes: await source.length(),
          onProgress: onProgress,
        );
        try {
          await source.delete();
        } catch (_) {
          // The picker cache is temporary anyway.
        }
      }
    } else {
      // No file path (content URI only): stream the bytes through Dart.
      await _copyStream(
        file.readAsByteStream(),
        target,
        expectedBytes: await file.length(),
        onProgress: onProgress,
      );
    }

    return PersistedVideo(
      path: target.path,
      name: file.name,
      sizeBytes: await target.length(),
    );
  }

  Future<void> _copyStream(
    Stream<List<int>> source,
    File target, {
    int? expectedBytes,
    ProgressCallback? onProgress,
  }) async {
    final sink = await target.open(mode: FileMode.write);
    var written = 0;
    try {
      await for (final chunk in source) {
        await sink.writeFrom(chunk);
        written += chunk.length;
        if (expectedBytes != null && expectedBytes > 0) {
          onProgress?.call((written / expectedBytes).clamp(0.0, 1.0).toDouble());
        }
      }
      await sink.flush();
    } catch (_) {
      await sink.close();
      if (await target.exists()) await target.delete();
      rethrow;
    }
    await sink.close();
    onProgress?.call(1);
  }

  /// Whether [path] still exists on disk.
  Future<bool> exists(String path) => File(path).exists();

  /// Deletes [path] only if it lives inside our storage directory, so a
  /// mistaken call can never remove the user's original file.
  Future<void> deleteManagedFile(String path) async {
    final directory = await storageDirectory();
    if (!p.isWithin(directory.path, path)) return;
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// Total size of all videos currently waiting in storage.
  Future<int> managedStorageBytes() async {
    final directory = await storageDirectory();
    var total = 0;
    await for (final entity in directory.list()) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }
}
