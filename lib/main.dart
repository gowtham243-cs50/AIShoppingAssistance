import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:camera/camera.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

import 'screens/auth/auth_wrapper.dart';
import 'services/cart_service.dart';
import 'services/inventory_service.dart';
import 'screens/chatbot/chatbot_screen.dart';
import 'config/config.dart';
import 'config/active_tenant.g.dart';
import 'config/web_theme_listener_stub.dart'
    if (dart.library.html) 'config/web_theme_listener_web.dart';

List<CameraDescription> cameras = [];

// ---------------------------------------------------------------------------
// Active brand — loaded from generated configuration at build time.
// ---------------------------------------------------------------------------
const BrandConfig _activeBrand = activeBrandConfig;

Future<void> _initDynamicTheme() async {
  const tenantId = String.fromEnvironment('TENANT_ID', defaultValue: 'qless');
  if (tenantId == 'qless') {
    BrandConfig.active = BrandConfig.qless();
    return; // Use default build-time activeBrandConfig
  }

  // 1. Try to load cached config from SharedPreferences (for instant offline startup)
  try {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString('cached_tenant_config_$tenantId');
    if (cached != null) {
      final decoded = json.decode(cached) as Map<String, dynamic>;
      BrandConfig.active = BrandConfig.fromJson(decoded);
      debugPrint('[ThemeService] Loaded cached tenant config for: $tenantId');
    } else {
      // Fallback presets if offline and no cache
      if (tenantId == 'lulu') BrandConfig.active = BrandConfig.lulu();
      if (tenantId == 'carrefour') BrandConfig.active = BrandConfig.carrefour();
    }
  } catch (e) {
    debugPrint('[ThemeService] Error loading cached tenant config: $e');
  }

  // 2. Fetch the latest config from Supabase in the background/startup
  try {
    final response = await Supabase.instance.client
        .from('tenants')
        .select()
        .eq('tenant_id', tenantId)
        .maybeSingle();

    if (response != null && response['is_active'] == true) {
      final config = BrandConfig.fromJson(response);
      BrandConfig.active = config;
      // Cache it for the next startup
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'cached_tenant_config_$tenantId',
        json.encode(response),
      );
      debugPrint(
        '[ThemeService] Successfully synchronized and cached theme config for: $tenantId',
      );
    }
  } catch (e) {
    debugPrint('[ThemeService] Failed to synchronize tenant config: $e');
  }
}

Future<void> main() async {
  BrandConfig.active = _activeBrand;
  WidgetsFlutterBinding.ensureInitialized();

  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint('Camera initialization error: $e');
  }

  try {
    await dotenv.load(fileName: ".env");
    debugPrint('[Dotenv] Loaded .env file successfully. Keys found: ${dotenv.env.keys.toList()}');
  } catch (e) {
    debugPrint('[Dotenv] Could not load .env file: $e');
  }

  // Initialize Supabase using values from .env (fallback to active backend URL if unconfigured or failed to load)
  const defaultSupabaseUrl = 'https://hwvkfsjhzjuqkqhuqtsg.supabase.co';
  const defaultSupabaseKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imh3dmtmc2poemp1cWtxaHVxdHNnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODEzNTc1MzcsImV4cCI6MjA5NjkzMzUzN30.FisdaztXlkT7tzu8QR49W-Pm4dzw5mc258fAJ-4TcRY';

  final envSupabaseUrl = dotenv.env['SUPABASE_URL']?.trim() ?? '';
  final envSupabaseKey = dotenv.env['SUPABASE_ANON_KEY']?.trim() ?? '';

  debugPrint('[Dotenv] SUPABASE_URL loaded: "$envSupabaseUrl"');
  debugPrint('[Dotenv] SUPABASE_ANON_KEY loaded: "${envSupabaseKey.isNotEmpty ? "Yes (len ${envSupabaseKey.length})" : "Empty"}"');

  final rawSupabaseUrl = envSupabaseUrl.isNotEmpty ? envSupabaseUrl : defaultSupabaseUrl;
  final rawSupabaseKey = envSupabaseKey.isNotEmpty ? envSupabaseKey : defaultSupabaseKey;
  final parsedSupabaseUrl = Uri.tryParse(rawSupabaseUrl);
  final isSupabaseValid = rawSupabaseUrl.isNotEmpty &&
      !rawSupabaseUrl.contains('<your-project-ref>') &&
      !rawSupabaseUrl.contains('<') &&
      !rawSupabaseUrl.contains('>') &&
      parsedSupabaseUrl != null &&
      parsedSupabaseUrl.hasScheme &&
      parsedSupabaseUrl.host.isNotEmpty &&
      rawSupabaseKey.isNotEmpty &&
      !rawSupabaseKey.contains('your_');

  final supabaseUrl = isSupabaseValid ? rawSupabaseUrl : defaultSupabaseUrl;
  final supabaseKey = isSupabaseValid ? rawSupabaseKey : defaultSupabaseKey;

  try {
    await Supabase.initialize(
      url: supabaseUrl,
      publishableKey: supabaseKey,
    );
    debugPrint(
      '[Main] Supabase initialized successfully ($supabaseUrl).',
    );
  } catch (e) {
    debugPrint('Supabase initialization error: $e');
  }

  // Load and cache tenant theme if specified via dart-define
  await _initDynamicTheme();

  // Pre-load dynamic product catalog, cart session, and chatbot history in parallel before rendering.
  await Future.wait([
    InventoryService().syncCatalogWithSupabase(),
    CartService().load(),
    ChatbotScreen.preloadHistory(),
  ]);

  runApp(MainApp(cameras: cameras));
}

class MainApp extends StatefulWidget {
  final List<CameraDescription> cameras;

  const MainApp({super.key, required this.cameras});

  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> {
  @override
  void initState() {
    super.initState();
    initWebThemeListener(() {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: BrandConfig.active.identity.appName,
      debugShowCheckedModeBanner: false,
      theme: BrandConfig.active.buildTheme(),
      home: AuthWrapper(cameras: widget.cameras),
    );
  }
}
