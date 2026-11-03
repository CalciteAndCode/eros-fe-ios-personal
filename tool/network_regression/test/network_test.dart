import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

import '../../../lib/network/app_dio/download_client.dart';
import '../../../lib/network/app_dio/exception.dart' as app;
import '../../../lib/network/app_dio/http_config.dart';
import '../../../lib/network/cloudflare_challenge.dart';

void main() {
  test('EX timeout values represent milliseconds, not hours', () {
    final options = const DioHttpConfig(
      baseUrl: 'https://exhentai.org',
      connectTimeout: 15000,
      sendTimeout: 8000,
      receiveTimeout: 25000,
    ).toBaseOptions();
    expect(options.connectTimeout, const Duration(seconds: 15));
    expect(options.sendTimeout, const Duration(seconds: 8));
    expect(options.receiveTimeout, const Duration(seconds: 25));
    expect(
      const DioHttpConfig().toBaseOptions().connectTimeout,
      const Duration(minutes: 1),
    );
  });

  test('site cookies are limited to HTTPS EH/EX domains', () {
    for (final url in [
      'https://exhentai.org/',
      'https://forums.e-hentai.org/index.php',
      'https://s.exhentai.org/image',
    ]) {
      expect(isEhSite(Uri.parse(url)), isTrue, reason: url);
    }
    for (final url in [
      'http://exhentai.org/',
      'https://exhentai.org.evil.example/',
      'https://evile-hentai.org/',
      'https://node.hath.network/image',
    ]) {
      expect(isEhSite(Uri.parse(url)), isFalse, reason: url);
    }
  });

  test(
    'EH, EX and forum clearance retain separate scopes and expiry',
    () async {
      final jar = CookieJar();
      final eh = Uri.parse('https://e-hentai.org/');
      final ex = Uri.parse('https://exhentai.org/');
      final forum = Uri.parse('https://forums.e-hentai.org/');
      await jar.saveFromResponse(eh, [Cookie('cf_clearance', 'eh')]);
      await jar.saveFromResponse(ex, [Cookie('cf_clearance', 'ex')]);
      await jar.saveFromResponse(forum, [Cookie('cf_clearance', 'forum')]);
      expect((await jar.loadForRequest(eh)).single.value, 'eh');
      expect((await jar.loadForRequest(ex)).single.value, 'ex');
      expect((await jar.loadForRequest(forum)).single.value, 'forum');
      expect(
        await jar.loadForRequest(Uri.parse('https://node.hath.network/')),
        isEmpty,
      );
      await jar.saveFromResponse(ex, [
        Cookie('cf_clearance', '')
          ..expires = DateTime.now().subtract(const Duration(days: 1)),
      ]);
      expect(await jar.loadForRequest(ex), isEmpty);
    },
  );

  group('real HTTP downloads', () {
    late HttpServer server;
    late Directory temp;
    late DownloadClient client;
    late String base;
    final payload = List<int>.generate(8192, (index) => index % 251);

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('eros-download-test-');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      client = DownloadClient(
        BaseOptions(
          connectTimeout: const Duration(seconds: 2),
          receiveTimeout: const Duration(seconds: 2),
        ),
      );
      client.interceptors.add(CloudflareChallengeInterceptor());
      server.listen((request) async {
        final response = request.response;
        try {
          if (request.uri.path == '/challenge' ||
              request.uri.path == '/challenge-no-header' ||
              request.uri.path == '/challenge-200') {
            response.statusCode =
                request.uri.path == '/challenge-200' ? 200 : 403;
            if (request.uri.path != '/challenge-no-header') {
              response.headers.set('cf-mitigated', 'challenge');
            }
            response.headers.contentType = ContentType.html;
            response.write(
              '<!doctype html><title>Just a moment...</title>'
              '<script src="https://challenges.cloudflare.com/test"></script>',
            );
          } else if (request.uri.path == '/forbidden') {
            response.statusCode = 403;
            response.headers.contentType = ContentType.text;
            response.write('Ordinary access denied');
          } else if (request.uri.path == '/empty') {
            response.contentLength = 0;
          } else if (request.uri.path == '/broken') {
            final socket = await response.detachSocket(writeHeaders: false);
            socket.add(ascii.encode('HTTP/1.1 200 OK\r\n'
                'Content-Length: ${payload.length}\r\n'
                'Connection: close\r\n\r\n'));
            socket.add(payload.sublist(0, 100));
            await socket.flush();
            await socket.close();
            return;
          } else if (request.uri.path == '/slow') {
            response.add(payload.sublist(0, 100));
            await response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 350));
            response.add(payload.sublist(100));
          } else if (request.uri.path == '/gzip') {
            response.headers.set('content-encoding', 'gzip');
            response.add(gzip.encode(payload));
          } else {
            if (request.uri.path == '/known') {
              response.contentLength = payload.length;
            }
            response.add(payload.sublist(0, 100));
            await response.flush();
            response.add(payload.sublist(100));
          }
          await response.close();
        } on HttpException {
          // Cancellation/timeout deliberately closes the client socket.
        } on SocketException {
          // Cancellation/timeout deliberately closes the client socket.
        }
      });
    });

    tearDown(() async {
      client.close(force: true);
      await server.close(force: true);
      if (temp.absolute.parent.path != Directory.systemTemp.absolute.path ||
          !temp.uri.pathSegments.where((part) => part.isNotEmpty).last.startsWith('eros-download-test-')) {
        throw StateError('Refusing to remove an unexpected test directory');
      }
      // Windows may release a cancelled file handle on the next event turn.
      for (var attempt = 0; attempt < 10; attempt++) {
        try {
          await temp.delete(recursive: true);
          break;
        } on FileSystemException {
          if (attempt == 9) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }
    });

    for (final route in ['/known', '/unknown', '/gzip']) {
      test(
        'completes $route only after the file is closed; awaits callback',
        () async {
          final file = File('${temp.path}/image.bin');
          final enteredCallback = Completer<void>();
          final releaseCallback = Completer<void>();
          var finished = false;
          var completions = 0;
          final totals = <int>[];
          final operation = downloadFile(
            client,
            '$base$route',
            file.path.toDioSavePath,
            onReceiveProgress: (_, total) => totals.add(total),
            onDownloadComplete: () async {
              completions++;
              expect(await file.readAsBytes(), payload);
              // On Windows, renaming also checks that the writer has closed it.
              await file.rename('${temp.path}/complete.bin');
              enteredCallback.complete();
              await releaseCallback.future;
            },
          ).then((_) => finished = true);
          await enteredCallback.future.timeout(const Duration(seconds: 5));
          expect(finished, isFalse);
          releaseCallback.complete();
          await operation;
          expect(finished, isTrue);
          expect(completions, 1);
          if (route != '/known') expect(totals, contains(-1));
        },
      );
    }

    test('empty response still completes exactly once', () async {
      final file = File('${temp.path}/empty.bin');
      var completions = 0;
      await downloadFile(client, '$base/empty', file.path.toDioSavePath,
          onDownloadComplete: () => completions++);
      expect(await file.length(), 0);
      expect(completions, 1);
    });

    test('failed completion callback propagates without downloading twice', () async {
      var completions = 0;
      await expectLater(
        downloadFile(client, '$base/known', '${temp.path}/callback.bin'.toDioSavePath,
            onDownloadComplete: () async {
          completions++;
          throw StateError('database write failed');
        }),
        throwsStateError,
      );
      expect(completions, 1);
    });

    test('truncated response never reports completion', () async {
      var completed = false;
      await expectLater(
        downloadFile(client, '$base/broken', '${temp.path}/broken.bin'.toDioSavePath,
            onDownloadComplete: () => completed = true),
        throwsA(isA<DioException>()),
      );
      expect(completed, isFalse);
    });

    test('cancelled transfer never reports completion', () async {
      final token = CancelToken();
      var completed = false;
      final operation = downloadFile(
        client,
        '$base/slow',
        '${temp.path}/cancelled.bin'.toDioSavePath,
        cancelToken: token,
        onReceiveProgress: (_, __) => token.cancel('test cancel'),
        onDownloadComplete: () => completed = true,
      );
      await expectLater(
        operation,
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      expect(completed, isFalse);
    });

    test('stalled response uses a finite receive timeout', () async {
      var completed = false;
      await expectLater(
        downloadFile(
          client,
          '$base/slow',
          '${temp.path}/timeout.bin'.toDioSavePath,
          options: Options(receiveTimeout: const Duration(milliseconds: 100)),
          onDownloadComplete: () => completed = true,
        ),
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.receiveTimeout,
          ),
        ),
      );
      expect(completed, isFalse);
    });

    for (final route in [
      '/challenge',
      '/challenge-no-header',
      '/challenge-200',
    ]) {
      test(
        '$route is a challenge, never an expired image or completed file',
        () async {
          var completed = false;
          final file = File('${temp.path}/challenge.bin');
          await expectLater(
            downloadFile(
              client,
              '$base$route',
              file.path.toDioSavePath,
              onDownloadComplete: () => completed = true,
            ),
            throwsA(
              isA<DioException>()
                  .having(
                    (e) => e.error,
                    'error',
                    isA<app.CloudflareChallengeException>(),
                  )
                  .having(
                    (e) => '${e.error}',
                    'message',
                    isNot(contains('<!doctype')),
                  ),
            ),
          );
          expect(completed, isFalse);
          expect(await file.exists(), isFalse);
        },
      );
    }

    test('ordinary 403 retains its error type', () async {
      await expectLater(
        downloadFile(
          client,
          '$base/forbidden',
          '${temp.path}/403.bin'.toDioSavePath,
        ),
        throwsA(
          isA<DioException>()
              .having((e) => e.response?.statusCode, 'status', 403)
              .having(
                (e) => e.error,
                'error',
                isNot(isA<app.CloudflareChallengeException>()),
              ),
        ),
      );
    });
  });
}
