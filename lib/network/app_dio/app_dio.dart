import 'package:collection/collection.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cache_interceptor/dio_cache_interceptor.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:eros_fe/common/global.dart';
import 'package:eros_fe/common/service/dns_service.dart';
import 'package:eros_fe/common/service/ehsetting_service.dart';
import 'package:eros_fe/const/const.dart';
import 'package:eros_fe/network/app_dio/proxy.dart';
import 'package:eros_fe/network/dio_interceptor/domain_fronting/domain_fronting.dart';
import 'package:eros_fe/network/dio_interceptor/eh_cookie_interceptor/eh_cookie_interceptor.dart';
import 'package:eros_fe/network/dio_interceptor/rate_limit/rate_limit_interceptor.dart';
import 'package:eros_fe/network/dio_interceptor/rate_limit/token_bucket_interceptor.dart';
import 'package:eros_fe/utils/logger.dart';
import 'package:get/get.dart' hide Response;
import 'package:native_dio_adapter/native_dio_adapter.dart';
import 'package:pretty_dio_logger/pretty_dio_logger.dart';

import '../api.dart';
import '../cloudflare_challenge.dart';
import 'download_client.dart';
import 'http_config.dart';

export 'http_config.dart';
export 'download_client.dart';

typedef AppHttpAdapter = HttpProxyAdapter;

class AppDio extends DownloadClient {
  AppDio({BaseOptions? options, DioHttpConfig? dioConfig}) {
    options ??= (dioConfig ?? const DioHttpConfig()).toBaseOptions(
      headers: <String, String>{
        'User-Agent': EHConst.CHROME_USER_AGENT,
        'Accept': EHConst.CHROME_ACCEPT,
        'Accept-Language': EHConst.CHROME_ACCEPT_LANGUAGE,
      },
    );
    this.options = options;

    logger.t('dioConfig ${dioConfig?.toString()}');

    httpClientAdapter = Get.find<EhSettingService>().nativeHttpClientAdapter
        ? NativeAdapter()
        : AppHttpAdapter(
            proxy: dioConfig?.proxy ?? '',
            skipCertificate: dioConfig?.domainFronting,
          );
    // httpClientAdapter = AppHttpAdapter(
    //   proxy: dioConfig?.proxy ?? '',
    //   skipCertificate: dioConfig?.domainFronting,
    // );

    interceptors.add(CloudflareChallengeInterceptor());
    interceptors.add(DioCacheInterceptor(options: Api.cacheOption));

    // Cookie管理
    if (dioConfig?.cookiesPath?.isNotEmpty ?? false) {
      interceptors.add(
        CookieManager(
          dioConfig!.cookiesPath == Global.appSupportPath
              ? Api.sharedCookieJar
              : PersistCookieJar(storage: FileStorage(dioConfig.cookiesPath)),
        ),
      );
    }

    interceptors.add(EhCookieInterceptor());

    // 限频 普通
    interceptors.add(
      RateLimitInterceptor(
        rateLimitInterval: const Duration(milliseconds: 200),
        globalLimit: false,
      ),
    );

    // 缩略图请求的限频配置
    final thumbRateLimitConfig = RateLimitConfig(
      maxTokens: 20,
      refillDuration: const Duration(milliseconds: 400),
    );

    // 限频 桶令牌
    interceptors.add(
      TokenBucketInterceptor(
        defaultMaxTokens: 10, // 默认令牌桶最大容量
        defaultRefillDuration: const Duration(milliseconds: 500), // 默认令牌补充间隔时间
        globalLimit: false, // 是否全局限制
        hostConfig: {
          // 缩略图 详情页
          r'^(?!-)[a-zA-Z0-9-]{1,63}(?<!-).hath.network$': thumbRateLimitConfig,
          // 缩略图
          'ehgt.org': thumbRateLimitConfig,
          // 缩略图 (封面?)
          's.exhentai.org': thumbRateLimitConfig,
          'e-hentai.org': RateLimitConfig(
            maxTokens: 5,
            refillDuration: const Duration(milliseconds: 800),
          ),
          'exhentai.org': RateLimitConfig(
            maxTokens: 5,
            refillDuration: const Duration(milliseconds: 800),
          ),
        },
      ),
    );

    // 限频 滑动窗口
    // interceptors.add(
    //   SlidingWindowInterceptor(
    //     defaultMaxRequests: 3, // 默认时间窗口内最大请求数
    //     defaultWindowDuration: const Duration(seconds: 2), // 默认时间窗口时长
    //     globalLimit: true, // false表示按主机限流
    //     hostConfig: {
    //       'ehgt.org': SlidingWindowConfig(
    //         maxRequests: 4,
    //         windowDuration: const Duration(milliseconds: 800),
    //       ),
    //       'e-hentai.org': SlidingWindowConfig(
    //         maxRequests: 3,
    //         windowDuration: const Duration(seconds: 1),
    //       ),
    //       'exhentai.org': SlidingWindowConfig(
    //         maxRequests: 3,
    //         windowDuration: const Duration(seconds: 1),
    //       ),
    //     },
    //   ),
    // );

    // if (kDebugMode) {
    //   interceptors.add(LogInterceptor(
    //       responseBody: false,
    //       error: true,
    //       requestHeader: false,
    //       responseHeader: false,
    //       request: true,
    //       requestBody: true));
    // }

    interceptors.add(
      PrettyDioLogger(
        requestHeader: true,
        requestBody: true,
        responseHeader: true,
        responseBody: false,
        maxWidth: 120,
        // logPrint: kDebugMode ? loggerSimple.d : loggerSimpleOnlyFile.d,
        logPrint: loggerSimpleOnlyFile.d,
      ),
    );

    // RetryInterceptor
    // interceptors.add(RetryInterceptor(
    //   dio: this,
    //   logPrint: logger.t, // specify log function (optional)
    //   retries: 3, // retry count (optional)
    //   retryDelays: const [
    //     // set delays between retries (optional)
    //     Duration(seconds: 1), // wait 1 sec before first retry
    //     Duration(seconds: 2), // wait 2 sec before second retry
    //     Duration(seconds: 3), // wait 3 sec before third retry
    //   ],
    // ));

    if (dioConfig?.interceptors?.isNotEmpty ?? false) {
      interceptors.addAll(dioConfig!.interceptors!);
    }

    if (dioConfig?.domainFronting ?? false) {
      final DnsService dnsServices = Get.find();
      final bool enableDoH = dnsServices.enableDoH;

      final customHosts = dnsServices.hostMapMerge;

      final domainFronting = DomainFronting(
        hosts: customHosts,
        dnsLookup: dnsServices.getHost,
      );

      // 允许证书错误的地址/ip
      final hostWhiteList = customHosts.values.flattened.toSet();

      // (httpClientAdapter as HttpProxyAdapter)
      //     .addOnHttpClientCreate((client) {
      //   client.badCertificateCallback =
      //       (X509Certificate cert, String host, int port) {
      //     // return hostWhiteList.contains(host);
      //     return true;
      //   };
      // });

      // 在其他插件添加完毕后再添加，以确保执行顺序正确
      domainFronting.bind(interceptors);
    }
  }
}
