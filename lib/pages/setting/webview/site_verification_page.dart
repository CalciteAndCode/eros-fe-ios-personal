import 'package:eros_fe/common/controller/user_controller.dart';
import 'package:eros_fe/common/global.dart';
import 'package:eros_fe/network/app_dio/dio_http_cli.dart';
import 'package:eros_fe/network/cloudflare_challenge.dart';
import 'package:eros_fe/network/request.dart';
import 'package:eros_fe/network/webview_session.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';

/// A normal, user-operated WebView. No background CAPTCHA solving or replay.
class SiteVerificationPage extends StatefulWidget {
  const SiteVerificationPage({super.key, required this.uri});
  final Uri uri;

  @override
  State<SiteVerificationPage> createState() => _SiteVerificationPageState();
}

class _SiteVerificationPageState extends State<SiteVerificationPage> {
  late final Future<void> _ready = seedSiteWebView(widget.uri);
  InAppWebViewController? _controller;
  bool _saving = false;
  String? _error;

  Future<void> _finish() async {
    final controller = _controller;
    if (controller == null || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final current = await controller.getUrl();
      if (current == null || current.host != widget.uri.host) {
        throw StateError('请在当前站点完成验证后再返回。');
      }
      final title = (await controller.getTitle())?.toLowerCase() ?? '';
      if (title.contains('just a moment') ||
          title.contains('attention required')) {
        throw StateError('网页验证尚未完成，请先在页面中完成验证。');
      }
      await persistSiteWebViewSession(controller, widget.uri);
      // Verify through the app's own network path before claiming success.
      final response = await DioHttpClient(dioConfig: globalDioConfig).get(
        widget.uri.toString(),
        options: getCacheOptions(refresh: true, forceCache: false),
      );
      if (!response.ok) {
        throw StateError(response.error?.message ?? '当前连接仍不可用，请检查网络后重试。');
      }
      if (mounted) Get.back(result: true);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text('网页验证 · ${widget.uri.host}'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _saving ? null : _finish,
          child:
              _saving ? const CupertinoActivityIndicator() : const Text('完成'),
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                _error ?? '请在网页中完成验证，再点右上角「完成」。验证期间保持同一网络。',
                style: TextStyle(
                  color: _error == null
                      ? CupertinoColors.secondaryLabel.resolveFrom(context)
                      : CupertinoColors.systemRed.resolveFrom(context),
                ),
              ),
            ),
            Expanded(
              child: FutureBuilder<void>(
                future: _ready,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return const Center(child: Text('无法打开验证页面，请返回后重试。'));
                  }
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CupertinoActivityIndicator());
                  }
                  return InAppWebView(
                    initialUrlRequest: URLRequest(url: WebUri.uri(widget.uri)),
                    initialSettings: InAppWebViewSettings(
                      useShouldOverrideUrlLoading: true,
                      userAgent:
                          Get.find<UserController>().user.value.userAgent,
                    ),
                    onWebViewCreated: (controller) => _controller = controller,
                    shouldOverrideUrlLoading: (controller, action) async {
                      final uri = action.request.url;
                      if (action.isForMainFrame &&
                          (uri == null || !isEhSite(uri))) {
                        return NavigationActionPolicy.CANCEL;
                      }
                      return NavigationActionPolicy.ALLOW;
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
