import 'dart:async';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../cloudflare_challenge.dart';
import 'exception.dart';

typedef SavePathBuild = String Function(Headers);

class DioSavePath {
  const DioSavePath({required this.pathBuilder});
  final SavePathBuild pathBuilder;

  String path(Headers headers) => pathBuilder(headers);
}

extension SavePathExt on String {
  DioSavePath get toDioSavePath => DioSavePath(pathBuilder: (_) => this);
}

/// Use Dio's maintained streaming/file implementation, including cancellation
/// and closing the file before the download future completes.
class DownloadClient extends DioForNative {
  DownloadClient([BaseOptions? options]) : super(options) {
    interceptors.add(InterceptorsWrapper(onResponse: (response, handler) {
      final body = response.data;
      final timeout = response.requestOptions.receiveTimeout;
      // Dio's streaming response is handed to its file writer after headers.
      // Enforce inactivity on the body too, rather than waiting indefinitely.
      if (body is ResponseBody && timeout != null && timeout > Duration.zero) {
        body.stream = body.stream.timeout(timeout, onTimeout: (sink) {
          sink.addError(DioException.receiveTimeout(
            timeout: timeout,
            requestOptions: response.requestOptions,
          ));
          sink.close();
        });
      }
      handler.next(response);
    }));
  }

  @override
  Future<Response> download(
    String urlPath,
    dynamic savePath, {
    ProgressCallback? onReceiveProgress,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
    bool deleteOnError = true,
    FileAccessMode fileAccessMode = FileAccessMode.write,
    String lengthHeader = Headers.contentLengthHeader,
    Object? data,
    Options? options,
  }) =>
      super.download(
        urlPath,
        savePath is DioSavePath ? savePath.path : savePath,
        onReceiveProgress: onReceiveProgress,
        queryParameters: queryParameters,
        cancelToken: cancelToken,
        deleteOnError: deleteOnError,
        fileAccessMode: fileAccessMode,
        lengthHeader: lengthHeader,
        data: data,
        options: options,
      );
}

Future<Response> downloadFile(
  Dio client,
  String url,
  DioSavePath savePath, {
  ProgressCallback? onReceiveProgress,
  Map<String, dynamic>? queryParameters,
  CancelToken? cancelToken,
  bool deleteOnError = true,
  String lengthHeader = Headers.contentLengthHeader,
  Object? data,
  Options? options,
  FutureOr<void> Function()? onDownloadComplete,
}) async {
  late final Response response;
  try {
    response = await client.download(
      url,
      savePath,
      onReceiveProgress: onReceiveProgress,
      queryParameters: queryParameters,
      cancelToken: cancelToken,
      deleteOnError: deleteOnError,
      lengthHeader: lengthHeader,
      data: data,
      options: options,
    );
  } on DioException catch (error) {
    // Dio converts a failed streaming response into text after interceptors.
    if (isCloudflareChallenge(error.response)) {
      final challenge = CloudflareChallengeException(
        error.requestOptions.uri.host,
      );
      throw error.copyWith(error: challenge, message: challenge.message);
    }
    rethrow;
  }
  // Content-Length may be absent (total == -1). Progress is never completion.
  await onDownloadComplete?.call();
  return response;
}
