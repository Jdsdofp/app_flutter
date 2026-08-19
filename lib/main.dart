import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

const String kioskUrl = 'https://analyticsapp.smartxhub.cloud/epi-station';

// Chaves usadas pelo próprio EpiCameraStation.tsx (loadConfig/saveConfig) —
// precisam bater exatamente com o que o front espera, senão o React não
// reconhece a config gravada pelo Flutter.
const String _kConfigKey = 'epi_station_config_v4';
const String _kApiKeyKey = 'epi_station_api_key';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Modo kiosk: some com barra de status/navegação do Android.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  runApp(const EpiKioskApp());
}

class EpiKioskApp extends StatelessWidget {
  const EpiKioskApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'EPI Kiosk',
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: const KioskWebView(),
    );
  }
}

class KioskWebView extends StatefulWidget {
  const KioskWebView({super.key});

  @override
  State<KioskWebView> createState() => _KioskWebViewState();
}

class _KioskWebViewState extends State<KioskWebView> with WidgetsBindingObserver {
  // Não é mais `late` — o pedido de permissão (_requestPermissions) é
  // assíncrono e pode demorar (diálogo do sistema esperando o usuário), mas
  // o primeiro build() roda antes disso terminar. Sem isso, o acesso a
  // `_controller` antes dele existir derruba o app com LateInitializationError.
  WebViewController? _controller;
  bool _loading = true;
  String? _error;
  bool _didInitialConfigCheck = false;
  bool _showSetup = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    await _requestPermissions();
    if (!mounted) return;
    _setupController();
  }

  Future<void> _requestPermissions() async {
    // Câmera (e microfone, caso o stream de vídeo peça) precisam ser
    // concedidas antes do WebView tentar getUserMedia, senão o prompt
    // interno do WebView falha silenciosamente em alguns Androids.
    await [Permission.camera, Permission.microphone].request();
  }

  void _setupController() {
    late final PlatformWebViewControllerCreationParams params;
    if (WebViewPlatform.instance is AndroidWebViewPlatform) {
      params = AndroidWebViewControllerCreationParams();
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }

    final controller = WebViewController.fromPlatformCreationParams(params);

    if (controller.platform is AndroidWebViewController) {
      final androidController = controller.platform as AndroidWebViewController;
      // Permite que a página reproduza vídeo/câmera sem gesto do usuário
      // e concede automaticamente pedidos de permissão de mídia (câmera)
      // originados de dentro da própria página web.
      androidController.setMediaPlaybackRequiresUserGesture(false);
      androidController.setOnShowFileSelector((params) async => []);
      AndroidWebViewController.enableDebugging(true);
      // Permite que a página HTTPS chame recursos HTTP locais (ESP32/fechadura).
      androidController.setMixedContentMode(MixedContentMode.alwaysAllow);
      androidController.setOnPlatformPermissionRequest((request) {
        request.grant();
      });
    }

    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => setState(() { _loading = true; _error = null; }),
          onPageFinished: (_) async {
            setState(() => _loading = false);
            // Só checa config no primeiro carregamento — depois de salvar via
            // setup nativo, o reload seguinte já vem com dados gravados, então
            // não precisamos checar de novo (evita reabrir o form à toa).
            if (!_didInitialConfigCheck) {
              _didInitialConfigCheck = true;
              final hasConfig = await _hasSavedConfig();
              if (mounted && !hasConfig) {
                setState(() => _showSetup = true);
              }
            }
          },
          onWebResourceError: (err) {
            // Só trata erro de navegação principal (frame raiz), não de
            // recursos secundários (imagens, fontes) que não devem
            // derrubar a tela inteira.
            if (err.isForMainFrame ?? true) {
              setState(() {
                _loading = false;
                _error = '${err.description} (${err.errorCode})';
              });
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(kioskUrl));

    if (!mounted) return;
    setState(() => _controller = controller);
  }

  // A API Key deixou de ser obrigatória no setup (Company ID e Zone ID que
  // são obrigatórios agora), então usamos a presença do objeto de config
  // completo — não mais a apiKey isolada — pra saber se a estação já foi
  // configurada nesse dispositivo.
  Future<bool> _hasSavedConfig() async {
    try {
      final result = await _controller!.runJavaScriptReturningResult(
        "window.localStorage.getItem('$_kConfigKey')",
      );
      final raw = result.toString();
      return raw != 'null' && raw.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  // Grava a config no localStorage do WebView no MESMO formato que o
  // ConfigModal do EpiCameraStation.tsx grava (StationConfig parcial — o
  // loadConfig() do front faz merge com os defaults pros campos ausentes).
  Future<void> _saveStationConfig(Map<String, dynamic> cfg, String apiKey) async {
    final cfgJson = jsonEncode(cfg);
    final js = '''
      window.localStorage.setItem('$_kConfigKey', ${jsonEncode(cfgJson)});
      window.localStorage.setItem('$_kApiKeyKey', ${jsonEncode(apiKey)});
    ''';
    await _controller!.runJavaScript(js);
    if (!mounted) return;
    setState(() { _showSetup = false; _loading = true; });
    await _controller!.reload();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Reaplica o modo imersivo ao voltar do background — o Android
    // costuma restaurar a barra de sistema quando o app é reaberto.
    if (state == AppLifecycleState.resumed) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _reload() {
    setState(() { _error = null; _loading = true; });
    _controller?.reload();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      // Ainda aguardando o pedido de permissão de câmera resolver antes de
      // criar o WebViewController.
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        top: false,
        bottom: false,
        child: Stack(
          children: [
            WebViewWidget(controller: controller),
            if (_loading)
              const Center(child: CircularProgressIndicator()),
            if (_error != null)
              Container(
                color: Colors.black,
                alignment: Alignment.center,
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.wifi_off, color: Colors.white54, size: 48),
                    const SizedBox(height: 16),
                    Text(
                      'Falha ao carregar a estação EPI.\n$_error',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: _reload,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Tentar novamente'),
                    ),
                  ],
                ),
              ),
            if (_showSetup)
              StationSetupScreen(onSave: _saveStationConfig),
          ],
        ),
      ),
    );
  }
}

/// Tela nativa de configuração inicial da estação — some pra sempre depois
/// da primeira config salva (só reaparece se o app for reinstalado ou o
/// localStorage do WebView for limpo). Funciona como um "login" da máquina.
class StationSetupScreen extends StatefulWidget {
  const StationSetupScreen({super.key, required this.onSave});

  final Future<void> Function(Map<String, dynamic> cfg, String apiKey) onSave;

  @override
  State<StationSetupScreen> createState() => _StationSetupScreenState();
}

class _StationSetupScreenState extends State<StationSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _apiKeyCtrl = TextEditingController();
  final _companyIdCtrl = TextEditingController(text: '1');
  final _apiBaseCtrl = TextEditingController(text: 'https://aihub.smartxhub.cloud');
  final _doorIdCtrl = TextEditingController(text: 'VI-5111');
  final _zoneIdCtrl = TextEditingController();
  final _lockIpCtrl = TextEditingController(text: '192.168.68.100');
  final _lockMsCtrl = TextEditingController(text: '5000');
  bool _saving = false;

  @override
  void dispose() {
    _apiKeyCtrl.dispose();
    _companyIdCtrl.dispose();
    _apiBaseCtrl.dispose();
    _doorIdCtrl.dispose();
    _zoneIdCtrl.dispose();
    _lockIpCtrl.dispose();
    _lockMsCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final cfg = <String, dynamic>{
      'apiKey': _apiKeyCtrl.text.trim(),
      'companyId': int.tryParse(_companyIdCtrl.text.trim()) ?? 1,
      'apiBase': _apiBaseCtrl.text.trim(),
      'doorId': _doorIdCtrl.text.trim(),
      'zoneId': _zoneIdCtrl.text.trim(),
      'lockIp': _lockIpCtrl.text.trim(),
      'lockMs': int.tryParse(_lockMsCtrl.text.trim()) ?? 5000,
    };
    try {
      await widget.onSave(cfg, _apiKeyCtrl.text.trim());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  InputDecoration _dec(String label, {String? hint}) => InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.04),
      );

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      width: double.infinity,
      height: double.infinity,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.shield_outlined, color: Colors.white70, size: 48),
                    const SizedBox(height: 12),
                    const Text(
                      'Configuração inicial da Estação',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Preencha os dados abaixo para liberar o uso deste tablet. '
                      'Só é pedido uma vez.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                    const SizedBox(height: 24),
                    TextFormField(
                      controller: _apiKeyCtrl,
                      style: const TextStyle(color: Colors.white),
                      obscureText: true,
                      decoration: _dec('API Key da Máquina'),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _companyIdCtrl,
                      style: const TextStyle(color: Colors.white),
                      keyboardType: TextInputType.number,
                      decoration: _dec('Company ID *'),
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Obrigatório' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _apiBaseCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: _dec('URL da API'),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _doorIdCtrl,
                            style: const TextStyle(color: Colors.white),
                            decoration: _dec('Door ID'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextFormField(
                            controller: _zoneIdCtrl,
                            style: const TextStyle(color: Colors.white),
                            decoration: _dec('Zone ID *'),
                            validator: (v) => (v == null || v.trim().isEmpty) ? 'Obrigatório' : null,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _lockIpCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: _dec('IP da Fechadura (ESP32)'),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _lockMsCtrl,
                      style: const TextStyle(color: Colors.white),
                      keyboardType: TextInputType.number,
                      decoration: _dec('Tempo aberta (ms)'),
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: _saving ? null : _submit,
                      icon: _saving
                          ? const SizedBox(
                              width: 16, height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.check),
                      label: Text(_saving ? 'Salvando...' : 'Salvar e iniciar'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
