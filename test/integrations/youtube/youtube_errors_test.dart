import 'package:content_automation/integrations/youtube/youtube_errors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String googleError(int code, String reason, [String message = 'msg']) =>
      '{"error":{"code":$code,"message":"$message","errors":[{"domain":"youtube.quota","reason":"$reason","message":"$message"}]}}';

  test('quota reasons map to a quota error with guidance', () {
    final e = YouTubeUploadException.fromResponse(
      403,
      googleError(403, 'quotaExceeded'),
    );
    expect(e.kind, YouTubeErrorKind.quota);
    expect(e.reason, 'quotaExceeded');
    expect(e.message, contains('10,000'));
    expect(e.isTransient, isFalse);
  });

  test('missing channel and permission problems are authorization errors', () {
    expect(
      YouTubeUploadException.fromResponse(
        401,
        googleError(401, 'youtubeSignupRequired'),
      ).message,
      contains('no YouTube channel'),
    );
    final forbidden = YouTubeUploadException.fromResponse(
      403,
      googleError(403, 'insufficientPermissions'),
    );
    expect(forbidden.kind, YouTubeErrorKind.authorization);
    expect(forbidden.message, contains('sign in again'));
  });

  test('metadata reasons are not transient', () {
    final e = YouTubeUploadException.fromResponse(
      400,
      googleError(400, 'invalidTags', 'Too many tags'),
    );
    expect(e.kind, YouTubeErrorKind.invalidMetadata);
    expect(e.message, allOf(contains('invalidTags'), contains('Too many tags')));
  });

  test('status codes decide when no reason is present', () {
    expect(
      YouTubeUploadException.fromResponse(503, '<html>oops</html>').kind,
      YouTubeErrorKind.server,
    );
    expect(
      YouTubeUploadException.fromResponse(404, '').kind,
      YouTubeErrorKind.sessionExpired,
    );
    expect(
      YouTubeUploadException.fromResponse(410, '').kind,
      YouTubeErrorKind.sessionExpired,
    );
    expect(
      YouTubeUploadException.fromResponse(401, 'nope').kind,
      YouTubeErrorKind.authorization,
    );
    final other = YouTubeUploadException.fromResponse(418, 'teapot');
    expect(other.kind, YouTubeErrorKind.other);
    expect(other.message, contains('418'));
    expect(other.message, contains('teapot'));
  });

  test('server errors are transient', () {
    expect(
      YouTubeUploadException.fromResponse(500, '{"error":"x"}').isTransient,
      isTrue,
    );
  });
}
