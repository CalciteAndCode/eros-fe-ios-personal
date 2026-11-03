import 'package:eros_fe/network/api.dart';
import 'package:eros_fe/network/webview_session.dart';
import 'package:get/get.dart';

class WebSettingController extends GetxController {
  late Future<void> setcookieFuture;

  Future<void> _setCookie() => seedSiteWebView(Uri.parse(Api.getBaseUrl()));

  @override
  void onInit() {
    super.onInit();
    setcookieFuture = _setCookie();
  }
}
