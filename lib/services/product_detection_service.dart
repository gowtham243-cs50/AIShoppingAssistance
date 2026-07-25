import 'dart:convert';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import '../models/cart_item_model.dart';
import 'inventory_service.dart';

abstract class ProductDetectionService {
  Future<CartItemModel?> detectItem(XFile photo);
}

class HuggingFaceProxyDetectionService implements ProductDetectionService {
  late final String _primaryUrl;
  late final String _backupUrl;
  late final String _chromaApiKey;

  HuggingFaceProxyDetectionService({String? primaryUrl, String? backupUrl}) {
    String pUrl =
        primaryUrl ??
        dotenv.env['PRIMARY_DETECTION_URL'] ??
        dotenv.env['VM_DETECTION_URL'] ??
        '';
    String bUrl = backupUrl ?? dotenv.env['BACKUP_DETECTION_URL'] ?? '';

    _primaryUrl = pUrl
        .replaceAll('/embed', '')
        .replaceAll('/health', '')
        .replaceAll(RegExp(r'/$'), '');
    _backupUrl = bUrl
        .replaceAll('/embed', '')
        .replaceAll('/health', '')
        .replaceAll(RegExp(r'/$'), '');
    _chromaApiKey = dotenv.env['CHROMA_API_KEY'] ?? '';

    debugPrint(
      '[ProductDetectionService] Configured Primary: "$_primaryUrl" | Backup: "$_backupUrl"',
    );
  }

  Future<http.Response> _sendDetectRequest(
    String baseUrl,
    List<int> bytes,
  ) async {
    final url = Uri.parse('$baseUrl/detect');
    final request = http.MultipartRequest('POST', url);
    request.files.add(
      http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: 'image.jpg',
        contentType: MediaType('image', 'jpeg'),
      ),
    );
    request.headers.addAll({'X-Chroma-Token': _chromaApiKey});
    final streamedResponse = await request.send().timeout(
      const Duration(seconds: 4),
    );
    return http.Response.fromStream(streamedResponse);
  }

  @override
  Future<CartItemModel?> detectItem(XFile photo) async {
    debugPrint('--- UNIFIED DETECT START ---');
    debugPrint('Captured photo path: ${photo.path}');

    if (_primaryUrl.isEmpty && _backupUrl.isEmpty) {
      debugPrint(
        '[ProductDetectionService] Error: Both Primary and Backup URLs are empty',
      );
      return null;
    }

    final bytes = await photo.readAsBytes();
    final overallStopwatch = Stopwatch()..start();
    http.Response? response;
    String activeUrl = _primaryUrl;

    // Try primary first if set
    if (_primaryUrl.isNotEmpty) {
      try {
        debugPrint('Attempting primary endpoint: $activeUrl/detect');
        final networkStopwatch = Stopwatch()..start();
        response = await _sendDetectRequest(activeUrl, bytes);
        networkStopwatch.stop();
        debugPrint(
          '[ProductDetectionService] Primary network roundtrip took: ${networkStopwatch.elapsedMilliseconds}ms',
        );
      } catch (e) {
        debugPrint(
          '[ProductDetectionService] Primary endpoint failed with exception: $e',
        );
      }
    } else {
      debugPrint(
        '[ProductDetectionService] Primary URL is empty. Reverting to secondary/backup endpoint...',
      );
    }

    // Fall back to backup if primary was empty, failed, or returned server error (5xx)
    if ((response == null || response.statusCode >= 500) &&
        _backupUrl.isNotEmpty) {
      activeUrl = _backupUrl;
      debugPrint('Falling back to backup endpoint: $activeUrl/detect');
      try {
        final networkStopwatch = Stopwatch()..start();
        response = await _sendDetectRequest(activeUrl, bytes);
        networkStopwatch.stop();
        debugPrint(
          '[ProductDetectionService] Backup network roundtrip took: ${networkStopwatch.elapsedMilliseconds}ms',
        );
      } catch (e) {
        debugPrint(
          '[ProductDetectionService] Backup endpoint also failed with exception: $e',
        );
      }
    }

    if (response == null) {
      debugPrint('[ProductDetectionService] All endpoints failed to respond.');
      overallStopwatch.stop();
      return null;
    }

    try {
      debugPrint('Detect Response Status Code: ${response.statusCode}');
      debugPrint('Detect Response Body: ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status'] == 'success') {
          final bool matchFound = data['match_found'] ?? false;
          if (!matchFound) {
            debugPrint(
              '[ProductDetectionService] No confident match found on server. Reason: ${data['reason']}',
            );
            overallStopwatch.stop();
            debugPrint(
              '[ProductDetectionService] Overall detection took: ${overallStopwatch.elapsedMilliseconds}ms',
            );
            return null;
          }

          final itemData = data['item'];
          if (itemData != null) {
            final String slug = itemData['slug'] ?? '';

            // Resolve product metadata locally in 0ms to bypass Supabase network query
            final inventoryService = InventoryService();
            final localProduct = inventoryService.getProductFromLocal(slug);

            final String sku = localProduct != null
                ? (localProduct['sku'] ?? 'UNLISTED')
                : (itemData['sku'] ?? 'UNLISTED');
            final String name = localProduct != null
                ? (localProduct['name'] ?? 'Unknown Product')
                : (itemData['name'] ?? 'Unknown Product');
            final double priceRupees = localProduct != null
                ? (localProduct['price_rupees'] as num?)?.toDouble() ?? 0.0
                : (itemData['price_rupees'] as num?)?.toDouble() ?? 0.0;

            final List<dynamic>? pricesRaw = localProduct != null
                ? localProduct['prices']
                : itemData['prices'];
            final List<double>? prices = pricesRaw
                ?.map((e) => (e as num).toDouble())
                .toList();

            overallStopwatch.stop();
            debugPrint(
              '[ProductDetectionService] Matched: $name (SLU: $slug, SKU: $sku, Price: ₹$priceRupees, LocalResolved: ${localProduct != null})',
            );
            debugPrint(
              '[ProductDetectionService] Overall detection took: ${overallStopwatch.elapsedMilliseconds}ms',
            );

            // Fetch thumbnail_url from Supabase in the background (non-blocking)
            inventoryService.getProductBySlug(slug);

            return CartItemModel(
              id: DateTime.now().millisecondsSinceEpoch.toString(),
              name: name,
              details: "SKU: $sku • ₹${priceRupees.toStringAsFixed(2)}",
              imageUrl: inventoryService.getImageUrl(slug),
              price: priceRupees,
              prices: prices,
              quantity: 1,
            );
          }
        } else {
          debugPrint(
            '[ProductDetectionService] Server error: ${data['message']}',
          );
        }
      } else {
        debugPrint(
          '[ProductDetectionService] Network error: Status ${response.statusCode}',
        );
      }
    } catch (e) {
      debugPrint('[ProductDetectionService] Exception parsing response: $e');
    }

    overallStopwatch.stop();
    debugPrint(
      '[ProductDetectionService] Overall detection took (failed/no-match): ${overallStopwatch.elapsedMilliseconds}ms',
    );
    debugPrint('--- UNIFIED DETECT END (NO MATCH) ---');
    return null;
  }
}
