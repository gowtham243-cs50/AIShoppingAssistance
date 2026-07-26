import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class InventoryService {
  static final InventoryService _instance = InventoryService._internal();
  factory InventoryService() => _instance;
  InventoryService._internal();

  SupabaseClient? get _supabase {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  final Map<String, String> _imageUrls = {};
  final Map<String, String> _thumbnailUrls = {}; // Supabase Storage URLs
  final Map<String, Map<String, dynamic>> _localProducts = {};
  final Map<String, Map<String, dynamic>> _supabaseProductsCache = {};

  Future<void> initLocalCatalog() async {
    try {
      final jsonStr = await rootBundle.loadString('inventory.json');
      final data = jsonDecode(jsonStr);
      final items = data['items'] as List;
      for (var item in items) {
        final slug = item['slug'] as String;
        _localProducts[slug] = Map<String, dynamic>.from(item);
        final imageUrl = item['image_url'] as String?;
        if (imageUrl != null) {
          _imageUrls[slug] = imageUrl;
        }
      }
      debugPrint(
        '[InventoryService] Loaded ${_localProducts.length} products from inventory.json',
      );
    } catch (e) {
      debugPrint('[InventoryService] Error loading inventory.json: $e');
    }
  }

  Future<void> syncCatalogWithSupabase() async {
    // First, run initLocalCatalog so we have a local fallback catalog ready immediately.
    await initLocalCatalog();

    if (!_hasCredentials()) {
      debugPrint(
        '[InventoryService] Cannot sync catalog: Supabase credentials not configured.',
      );
      return;
    }

    try {
      debugPrint(
        '[InventoryService] Fetching dynamic catalog from Supabase...',
      );
      final client = _supabase;
      if (client == null) return;
      final response = await client
          .from('inventory')
          .select(
            'sku, slug, name, price_rupees, prices, staging_dirs, thumbnail_url',
          );

      if (response.isNotEmpty) {
        final List<dynamic> items = response;
        int count = 0;
        for (var item in items) {
          final slug = item['slug'] as String?;
          if (slug != null) {
            _localProducts[slug] = Map<String, dynamic>.from(item);
            final imageUrl = item['thumbnail_url'] as String?;
            if (imageUrl != null && imageUrl.isNotEmpty) {
              _thumbnailUrls[slug] = imageUrl;
            }
            count++;
          }
        }
        debugPrint(
          '[InventoryService] Successfully synchronized $count products from Supabase.',
        );
      } else {
        debugPrint('[InventoryService] Supabase catalog query returned empty.');
      }
    } catch (e) {
      debugPrint(
        '[InventoryService] Failed to sync catalog with Supabase (using local catalog): $e',
      );
    }
  }

  Map<String, dynamic>? getProductFromLocal(String slug) {
    return _localProducts[slug];
  }

  String? getSlugByName(String name) {
    for (var entry in _localProducts.entries) {
      if (entry.value['name'] == name) {
        return entry.key;
      }
    }
    return null;
  }

  List<Map<String, dynamic>> getAllProducts() {
    return _localProducts.values.toList();
  }

  String getImageUrl(String slug) {
    // Prefer Supabase Storage thumbnail over local JSON fallback
    if (_thumbnailUrls.containsKey(slug)) return _thumbnailUrls[slug]!;
    return _imageUrls[slug] ??
        "https://images.unsplash.com/photo-1542838132-92c53300491e?q=80&w=200&auto=format&fit=crop";
  }

  void cacheThumbnailUrl(String slug, String? url) {
    if (url != null && url.isNotEmpty) {
      _thumbnailUrls[slug] = url;
    }
  }

  /// Helper to check if credentials are set in .env and valid
  bool _hasCredentials() {
    final url = dotenv.env['SUPABASE_URL']?.trim();
    final key = dotenv.env['SUPABASE_ANON_KEY']?.trim();
    if (url == null || url.isEmpty || key == null || key.isEmpty) return false;
    if (url.contains('<your-project-ref>') ||
        url.contains('<') ||
        url.contains('>')) {
      return false;
    }
    final parsed = Uri.tryParse(url);
    return parsed != null && parsed.hasAbsolutePath && parsed.host.isNotEmpty;
  }

  /// Queries the 'inventory' table in Supabase for a single product matching the slug.
  Future<Map<String, dynamic>?> getProductBySlug(String slug) async {
    // Optimization: Return cached product details if already fetched
    if (_supabaseProductsCache.containsKey(slug)) {
      debugPrint(
        '[InventoryService] Returning cached Supabase product details for slug: "$slug"',
      );
      return _supabaseProductsCache[slug];
    }

    if (!_hasCredentials()) {
      debugPrint(
        '[InventoryService] Cannot query: Supabase credentials are not configured in .env',
      );
      return null;
    }

    final client = _supabase;
    if (client == null) return null;

    debugPrint('[InventoryService] Querying Supabase for slug: "$slug"');
    try {
      final response = await client
          .from('inventory')
          .select(
            'sku, slug, name, price_rupees, prices, staging_dirs, thumbnail_url',
          )
          .eq('slug', slug)
          .maybeSingle();

      if (response != null) {
        _supabaseProductsCache[slug] = response;
        // Cache the thumbnail URL so getImageUrl() returns it immediately
        cacheThumbnailUrl(slug, response['thumbnail_url'] as String?);
        debugPrint(
          '[InventoryService] Successfully found product in Supabase: $response',
        );
      } else {
        debugPrint(
          '[InventoryService] No product found in Supabase matching slug: "$slug"',
        );
      }
      return response;
    } catch (e) {
      debugPrint(
        '[InventoryService] Error querying Supabase for slug "$slug": $e',
      );
      return null;
    }
  }

  /// Verifies connection to Supabase by performing a simple query.
  Future<String> checkConnectivity() async {
    if (!_hasCredentials()) {
      return "Failed: Credentials not set in .env";
    }

    final client = _supabase;
    if (client == null) {
      return "Failed: Supabase client not initialized";
    }

    try {
      await client.from('inventory').select('sku').limit(1);
      return "Connected: OK";
    } on TypeError catch (_) {
      return "Failed: Cast error (check if 'inventory' table exists in Supabase)";
    } catch (e) {
      return "Failed: $e";
    }
  }

  static String getSizeForProduct({
    required String name,
    required String slug,
    required double price,
  }) {
    final cleanSlug = slug.toLowerCase();

    if (cleanSlug.contains('cheez-puffs-cheetos')) {
      if (price <= 10) return '25g';
      return '50g';
    }
    if (cleanSlug.contains('ceregrow-multigrain-cereal-nestle')) {
      if (price <= 300) return '300g';
      return '600g';
    }
    if (cleanSlug.contains('american-style-cream-and-onion-chips-lays')) {
      if (price <= 10) return '20g';
      if (price <= 20) return '50g';
      if (price <= 35) return '90g';
      return '130g';
    }
    if (cleanSlug.contains('corn-flakes-original-kelloggs')) {
      if (price <= 120) return '250g';
      return '500g';
    }
    if (cleanSlug.contains('health-drink-boost')) {
      if (price <= 120) return '200g';
      if (price <= 260) return '500g';
      return '1kg';
    }
    if (cleanSlug.contains('indias-magic-masala-chips-lays')) {
      if (price <= 20) return '50g';
      return '115g';
    }
    if (cleanSlug.contains('spanish-tomato-tango-chips-lays')) {
      if (price <= 20) return '50g';
      return '115g';
    }
    if (cleanSlug.contains('womens-plus-caramel-horlicks')) {
      if (price >= 290) return '400g (Jar)';
      return '400g (Refill)';
    }

    // Generic fallback based on price
    if (price <= 20) return '50g';
    if (price <= 50) return '100g';
    if (price <= 150) return '250g';
    if (price <= 300) return '500g';
    return '1kg';
  }
}
