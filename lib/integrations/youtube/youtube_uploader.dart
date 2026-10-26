import 'dart:io';

import 'package:googleapis/youtube/v3.dart' as yt;
import 'package:http/http.dart' as http;

import '../../core/constants.dart';
import '../../core/utils/formatters.dart';
import '../../data/models/enums.dart';
import '../../data/models/scheduled_upload.dart';
import '../../services/settings_service.dart';
import '../uploaders/video_uploader.dart';
import 'google_auth_client.dart';
import 'google_auth_gateway.dart';
import 'resumable_upload.dart';
import 'youtube_errors.dart';
import 'youtube_metadata.dart';

/// Uploads a scheduled video to YouTube with the Data API v3 resumable
/// protocol, as the Google account chosen in Settings.
///
/// * Metadata (title / description / tags) is applied in the session request,
///   privacy is `public` with no `publishAt`, so the video goes live as soon
///   as YouTube finishes processing.
/// * Progress is reported per 64 KiB as bytes leave the device.
/// * The session URI is persisted through [UploadSessionSaver]; if the process
///   dies the engine runs the uploader again and it continues from the last
///   byte YouTube confirmed.
class YouTubeUploader implements VideoUploader {
  YouTubeUploader({
    required GoogleAuthGateway auth,
    http.Client? client,
    this.chunkSize = AppConstants.youtubeUploadChunkSize,
    this.verifyAfterUpload = true,
    Future<void> Function(Duration delay)? sleep,
    DateTime Function()? clock,
    Uri? uploadEndpoint,
    String apiRootUrl = 'https://youtube.googleapis.com/',
  }) : _auth = auth,
       _client = client ?? http.Client(),
       _sleep = sleep,
       _clock = clock ?? DateTime.now,
       _uploadEndpoint = uploadEndpoint,
       _apiRootUrl = apiRootUrl;

  final GoogleAuthGateway _auth;
  final http.Client _client;
  final int chunkSize;

  /// After the upload, ask YouTube for the processing status once and log it.
  final bool verifyAfterUpload;

  final Future<void> Function(Duration delay)? _sleep;
  final DateTime Function() _clock;
  final Uri? _uploadEndpoint;
  final String _apiRootUrl;

  @override
  UploadPlatform get platform => UploadPlatform.youtube;

  @override
  Future<UploadOutcome> upload(
    ScheduledUpload upload, {
    required AppSettings settings,
    required UploadProgressCallback onProgress,
    required UploadLogger log,
    required UploadSessionSaver saveSession,
  }) async {
    if (settings.youtubeClientId.trim().isEmpty) {
      return const UploadOutcome.failure(
        'YouTube is not set up: add the Web OAuth client ID in Settings → '
        'YouTube and sign in with Google.',
      );
    }
    if (!settings.isYouTubeSignedIn) {
      return const UploadOutcome.failure(
        'YouTube is not signed in: open Settings → YouTube → "Sign in with '
        'Google" on this phone.',
      );
    }

    final file = File(upload.videoPath);
    if (!await file.exists()) {
      return UploadOutcome.failure(
        'Video file not found on this device: ${upload.videoPath}',
      );
    }
    final totalBytes = await file.length();
    if (totalBytes == 0) {
      return const UploadOutcome.failure('The video file is empty (0 bytes).');
    }

    try {
      await _auth.initialize(serverClientId: settings.youtubeClientId.trim());
      final tokens = GatewayTokenSource(
        gateway: _auth,
        email: settings.youtubeAccountEmail,
        clock: _clock,
      );
      // Fail fast with a readable message when the device lost authorization.
      await tokens.token();

      final metadata = YouTubeMetadata.fromUpload(upload);
      for (final warning in metadata.warnings) {
        await log(warning);
      }

      final transport = YouTubeResumableUpload(
        client: _client,
        tokens: tokens,
        chunkSize: chunkSize,
        sleep: _sleep,
        endpoint: _uploadEndpoint,
      );
      final contentType = _contentTypeFor(upload.videoName);

      // --- Resume or start -------------------------------------------------
      Uri? session;
      var offset = 0;
      final stored = upload.youtubeUploadUri;
      if (stored != null && stored.isNotEmpty) {
        try {
          final status = await transport.queryStatus(
            Uri.parse(stored),
            totalBytes,
          );
          if (status.isCompleted) {
            return await _complete(
              status.video!,
              totalBytes: totalBytes,
              tokens: tokens,
              onProgress: onProgress,
              log: log,
              saveSession: saveSession,
            );
          }
          session = Uri.parse(stored);
          offset = status.nextOffset;
          await log(
            'Resuming the YouTube upload at ${Formatters.bytes(offset)} of '
            '${Formatters.bytes(totalBytes)}.',
          );
        } on YouTubeUploadException catch (e) {
          if (e.kind != YouTubeErrorKind.sessionExpired) rethrow;
          await log(
            'The previous YouTube upload session expired; starting again.',
          );
          await saveSession(null);
        }
      }

      if (session == null) {
        session = await transport.startSession(
          metadata: metadata.toJson(),
          totalBytes: totalBytes,
          contentType: contentType,
        );
        await saveSession(session.toString());
        await log(
          'YouTube upload session opened for "${metadata.title}" '
          '(${Formatters.bytes(totalBytes)}, public when processed).',
        );
      }

      // --- Transfer --------------------------------------------------------
      onProgress(offset / totalBytes);
      Map<String, Object?> video;
      try {
        video = await transport.uploadFile(
          session: session,
          file: file,
          totalBytes: totalBytes,
          startOffset: offset,
          contentType: contentType,
          onProgress: (sent) => onProgress(sent / totalBytes),
        );
      } on YouTubeUploadException catch (e) {
        if (e.kind != YouTubeErrorKind.sessionExpired) rethrow;
        await log('YouTube dropped the upload session; uploading from the start.');
        session = await transport.startSession(
          metadata: metadata.toJson(),
          totalBytes: totalBytes,
          contentType: contentType,
        );
        await saveSession(session.toString());
        video = await transport.uploadFile(
          session: session,
          file: file,
          totalBytes: totalBytes,
          contentType: contentType,
          onProgress: (sent) => onProgress(sent / totalBytes),
        );
      }

      return await _complete(
        video,
        totalBytes: totalBytes,
        tokens: tokens,
        onProgress: onProgress,
        log: log,
        saveSession: saveSession,
      );
    } on MissingAuthorizationException catch (e) {
      return UploadOutcome.failure(e.message);
    } on GoogleAuthException catch (e) {
      return UploadOutcome.failure('YouTube sign-in problem: ${e.message}');
    } on YouTubeUploadException catch (e) {
      if (e.kind == YouTubeErrorKind.sessionExpired ||
          e.kind == YouTubeErrorKind.invalidMetadata) {
        await saveSession(null);
      }
      return UploadOutcome.failure(e.message);
    } on FileSystemException catch (e) {
      return UploadOutcome.failure(
        'Could not read the video file: ${e.message}',
      );
    }
  }

  Future<UploadOutcome> _complete(
    Map<String, Object?> video, {
    required int totalBytes,
    required AccessTokenSource tokens,
    required UploadProgressCallback onProgress,
    required UploadLogger log,
    required UploadSessionSaver saveSession,
  }) async {
    final id = video['id']?.toString();
    await saveSession(null);
    onProgress(1);
    if (id == null || id.isEmpty) {
      return const UploadOutcome.failure(
        'YouTube accepted the upload but did not return a video id.',
      );
    }
    await log(
      'YouTube received all ${Formatters.bytes(totalBytes)} '
      '(video id $id, https://youtu.be/$id). YouTube is processing it now; '
      'it becomes public automatically when processing finishes.',
    );
    if (verifyAfterUpload) {
      await _logProcessingStatus(id, tokens, log);
    }
    return UploadOutcome.success(remoteId: id);
  }

  /// One `videos.list` call (read-only scope) to surface YouTube's own view
  /// of the upload; purely informational.
  Future<void> _logProcessingStatus(
    String videoId,
    AccessTokenSource tokens,
    UploadLogger log,
  ) async {
    try {
      final api = yt.YouTubeApi(
        GoogleAuthClient(_client, tokens),
        rootUrl: _apiRootUrl,
      );
      final response = await api.videos
          .list(['status', 'processingDetails'], id: [videoId])
          .timeout(const Duration(seconds: 30));
      final item = response.items?.firstOrNull;
      if (item == null) {
        await log('YouTube status check: video not visible yet (still processing).');
        return;
      }
      final status = item.status;
      final processing = item.processingDetails?.processingStatus;
      final parts = <String>[
        if (status?.uploadStatus != null) 'upload ${status!.uploadStatus}',
        if (processing != null) 'processing $processing',
        if (status?.privacyStatus != null) 'privacy ${status!.privacyStatus}',
        if (status?.failureReason != null) 'failure ${status!.failureReason}',
        if (status?.rejectionReason != null)
          'rejected ${status!.rejectionReason}',
      ];
      await log('YouTube status check: ${parts.join(', ')}.');
    } catch (e) {
      await log('YouTube status check skipped: $e');
    }
  }

  static String _contentTypeFor(String fileName) {
    final dot = fileName.lastIndexOf('.');
    final ext = dot < 0 ? '' : fileName.substring(dot + 1).toLowerCase();
    return switch (ext) {
      'mp4' || 'm4v' => 'video/mp4',
      'mov' => 'video/quicktime',
      'webm' => 'video/webm',
      'mkv' => 'video/x-matroska',
      'avi' => 'video/x-msvideo',
      '3gp' => 'video/3gpp',
      _ => 'video/*',
    };
  }
}
