import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 应用内 WebView 页面
///
/// 用途：点击配置中心线路后，**在应用内**打开 URL（替代 `url_launcher`
/// 跳外部浏览器），让用户保持在 TVBox 上下文。
///
/// 来自 [_openConfigCenterUrl](home/view.dart) 的 push 入口，参数：
/// - [url]：要打开的 URL
/// - [title]：AppBar 标题（可选，默认用 URL）
class InAppWebViewPage extends StatefulWidget {
  final String url;
  final String? title;

  const InAppWebViewPage({
    super.key,
    required this.url,
    this.title,
  });

  @override
  State<InAppWebViewPage> createState() => _InAppWebViewPageState();
}

class _InAppWebViewPageState extends State<InAppWebViewPage> {
  late final WebViewController _controller;
  int _loadingProgress = 0;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (mounted) {
              setState(() {
                _loadingProgress = progress;
              });
            }
          },
          onPageStarted: (url) {
            if (mounted) {
              setState(() {
                _loadingProgress = 0;
              });
            }
          },
          onWebResourceError: (error) {
            // 仅打印错误，不弹 dialog（避免遮挡；用户在加载条上能看到失败）
            debugPrint(
                '[InAppWebView] 资源错误: ${error.errorCode} ${error.description} url=${error.url}');
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          widget.title ?? widget.url,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          // 刷新
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: () => _controller.reload(),
          ),
        ],
      ),
      body: Column(
        children: [
          // 加载进度条
          if (_loadingProgress > 0 && _loadingProgress < 100)
            LinearProgressIndicator(
              value: _loadingProgress / 100.0,
              minHeight: 2,
              backgroundColor: Colors.white12,
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
            ),
          Expanded(
            child: WebViewWidget(controller: _controller),
          ),
        ],
      ),
    );
  }
}
