import 'dart:async';

import 'package:dio/dio.dart';

import 'app_dio/exception.dart';

bool isEhSite(Uri uri) =>
    uri.scheme == 'https' &&
    (uri.host == 'e-hentai.org' ||
        uri.host.endsWith('.e-hentai.org') ||
        uri.host == 'exhentai.org' ||
        uri.host.endsWith('.exhentai.org'));

bool isCloudflareChallenge(Response? response) {
  if (response == null) return false;
  if (response.headers.value('cf-mitigated')?.toLowerCase() == 'challenge') {
    return true;
  }
  final data = response.data;
  if (data is! String) return false;
  final body = data.length > 16384 ? data.substring(0, 16384) : data;
  return (body.contains('challenges.cloudflare.com') ||
          body.contains('/cdn-cgi/challenge-platform/')) &&
      (body.toLowerCase().contains('<title>just a moment') ||
          response.statusCode == 403 ||
          response.statusCode == 503);
}

class CloudflareChallengeInterceptor extends Interceptor {
  DioException _exception(Response response) {
    final body = response.data;
    if (body is ResponseBody) {
      unawaited(body.stream.listen((_) {}, onError: (Object _) {}).cancel());
    }
    response.data = null;
    final error = CloudflareChallengeException(
      response.requestOptions.uri.host,
    );
    return DioException(
      requestOptions: response.requestOptions,
      response: response,
      error: error,
      message: error.message,
    );
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (isCloudflareChallenge(response)) {
      handler.reject(_exception(response));
      return;
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (isCloudflareChallenge(err.response)) {
      handler.next(_exception(err.response!));
      return;
    }
    handler.next(err);
  }
}
