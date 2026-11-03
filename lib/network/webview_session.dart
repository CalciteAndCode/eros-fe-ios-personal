import 'dart:io' as io;

import 'package:eros_fe/common/controller/user_controller.dart';
import 'package:eros_fe/extension.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';

import 'api.dart';
import 'cloudflare_challenge.dart';

/// Copy only cookies applicable to this site. Never clear other WebView sessions.
Future<void> seedSiteWebView(Uri uri) async {
  if (!isEhSite(uri)) return;
  final cookieManager = CookieManager.instance();
  final cookies = <String, io.Cookie>{
    for (final cookie in Get.find<UserController>().user.value.cookies)
      cookie.name: cookie,
    for (final cookie in await (await Api.cookieJar).loadForRequest(uri))
      cookie.name: cookie,
  };
  for (final cookie in cookies.values) {
    await cookieManager.setCookie(
      url: WebUri.uri(uri),
      name: cookie.name,
      value: cookie.value,
      domain: cookie.domain?.isNotEmpty == true ? cookie.domain : null,
      path: cookie.path?.isNotEmpty == true ? cookie.path! : '/',
      expiresDate: cookie.expires?.millisecondsSinceEpoch,
      isSecure: cookie.secure,
      isHttpOnly: cookie.httpOnly,
    );
  }
}

/// Preserve domain/path/expiry; an EX clearance must not overwrite an EH one.
Future<List<io.Cookie>> persistSiteWebViewSession(
  InAppWebViewController controller,
  Uri uri,
) async {
  if (!isEhSite(uri)) return [];
  final cookies = await CookieManager.instance().getCookies(
    url: WebUri.uri(uri),
  );
  final ioCookies = cookies.map((cookie) {
    final result = io.Cookie(cookie.name, '${cookie.value}')
      ..domain = cookie.domain ?? uri.host
      ..path = cookie.path ?? '/'
      ..httpOnly = cookie.isHttpOnly ?? false
      ..secure = cookie.isSecure ?? uri.scheme == 'https';
    final expires = cookie.expiresDate;
    if (expires != null) {
      result.expires = DateTime.fromMillisecondsSinceEpoch(
        expires.toInt(),
        isUtc: true,
      );
    }
    return result;
  }).toList();
  final ua = await controller.evaluateJavascript(source: 'navigator.userAgent');
  if (ua is! String || ua.trim().isEmpty) {
    throw StateError('无法读取网页浏览器标识，请重新打开网页验证。');
  }
  await (await Api.cookieJar).saveFromResponse(uri, ioCookies);
  final userController = Get.find<UserController>();
  userController.user(
    userController.user.value.copyWith(userAgent: ua.trim().oN),
  );
  return ioCookies;
}
