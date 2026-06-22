import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../common/theme.dart';
import '../../services/app_state.dart';

/// 初始设置页面 - 对应 Swift setupView
class SetupPage extends StatefulWidget {
  const SetupPage({super.key});

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  final _urlController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;
  String _loadingPhaseText = '';

  static const String _configUrlKey = 'tvbox_config_url';

  @override
  void initState() {
    super.initState();
    _loadSavedConfig();
  }

  Future<void> _loadSavedConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final savedUrl = prefs.getString(_configUrlKey) ?? '';

    if (savedUrl.isNotEmpty) {
      _urlController.text = savedUrl;

      // 自动加载已保存的配置
      setState(() {
        _isLoading = true;
        _loadingPhaseText = '正在加载配置...';
      });

      try {
        final appState = Get.find<AppState>();
        await appState.loadConfigWithLive(vodUrl: savedUrl);

        if (appState.isConfigLoaded.value && mounted) {
        } else {
          setState(() {
            _isLoading = false;
            _errorMessage = appState.configLoadError.value ?? '配置加载失败';
            _loadingPhaseText = '';
          });
        }
      } catch (e) {
        setState(() {
          _isLoading = false;
          _errorMessage = e.toString();
          _loadingPhaseText = '';
        });
      }
    }
  }

  Future<void> _loadConfig() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _loadingPhaseText = '正在加载配置...';
    });

      final appState = Get.find<AppState>();

    // 保存配置 URL
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_configUrlKey, url);

    // 监听加载阶段变化
    Worker? phaseWorker;
    phaseWorker = ever(appState.loadingPhase, (LoadingPhase phase) {
      if (mounted && phase.isLoading) {
        setState(() {
          _loadingPhaseText = phase.description;
        });
      }
    });

    try {
      await appState.loadConfigWithLive(vodUrl: url);

      phaseWorker.dispose();

      if (appState.isConfigLoaded.value && mounted) {
      } else {
        setState(() {
          _isLoading = false;
          _errorMessage = appState.configLoadError.value ?? '配置加载失败';
          _loadingPhaseText = '';
        });
      }
    } catch (e) {
      phaseWorker.dispose();
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString();
        _loadingPhaseText = '';
      });
    }
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      _urlController.text = data.text!;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF0F0F0F),
              Color(0xFF141414),
              Color(0xFF0F0F0F),
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 30),
              child: Column(
                children: [
                  const SizedBox(height: 60),
                  // Logo
                  Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(
                        colors: [
                          AppTheme.accentColor,
                          AppTheme.accentLightColor
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color:
                              AppTheme.accentColor.withValues(alpha: 0.4),
                          blurRadius: 20,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.play_circle_filled,
                      size: 50,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: AppTheme.spacingXL),
                  const Text(
                    'TVBox',
                    style: TextStyle(
                      fontSize: 48,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.textPrimary,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: AppTheme.spacingSM),
                  const Text(
                    '极致视听 · 简洁至上',
                    style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      color: AppTheme.textSecondary,
                      letterSpacing: 4,
                    ),
                  ),
                  const SizedBox(
                      height:
                          AppTheme.spacingXXL + AppTheme.spacingSM),
                  // 接口配置
                  Container(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.only(
                        left: AppTheme.spacingXS),
                    child: const Text(
                      '接口配置',
                      style: TextStyle(
                        fontSize: AppTheme.fontHeadline,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppTheme.spacingMD),
                  // 配置地址
                  Container(
                    decoration: BoxDecoration(
                      color: AppTheme.backgroundSecondary,
                      borderRadius: BorderRadius.circular(15),
                      border:
                          Border.all(color: AppTheme.borderLight),
                    ),
                    child: Row(
                      children: [
                        const SizedBox(width: 14),
                        const Icon(Icons.link,
                            color: AppTheme.accentColor, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: _urlController,
                            style: const TextStyle(
                                color: AppTheme.textPrimary),
                            decoration: const InputDecoration(
                              hintText: '请输入配置地址 (URL)',
                              hintStyle: TextStyle(
                                  color: AppTheme.textTertiary),
                              border: InputBorder.none,
                              contentPadding:
                                  EdgeInsets.symmetric(vertical: 14),
                            ),
                            keyboardType: TextInputType.url,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.content_paste,
                              color: AppTheme.accentColor, size: 20),
                          onPressed: _pasteFromClipboard,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppTheme.spacingXXL),
                  // 确认按钮
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _loadConfig,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.accentColor,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                            vertical: AppTheme.spacingLG),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
                      ),
                      child: _isLoading
                          ? Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  _loadingPhaseText.isNotEmpty
                                      ? _loadingPhaseText
                                      : '正在解析配置...',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16),
                                ),
                              ],
                            )
                          : const Text(
                              '开启影音之旅',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16),
                            ),
                    ),
                  ),
                  if (_errorMessage != null) ...[
                    const SizedBox(height: AppTheme.spacingLG),
                    Container(
                      padding:
                          const EdgeInsets.all(AppTheme.spacingMD),
                      decoration: BoxDecoration(
                        color:
                            Colors.red.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.error,
                              color: Colors.red, size: 16),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _errorMessage!,
                              style: const TextStyle(
                                  color: Colors.red,
                                  fontSize: AppTheme.fontCaption),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 50),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
