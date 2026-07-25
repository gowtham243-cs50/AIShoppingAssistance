import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../models/cart_item_model.dart';
import '../../../models/fulfillment_option.dart';
import '../../../services/inventory_service.dart';
import 'payment_sheet.dart';
import 'missing_regulars_sheet.dart';
import 'fulfillment_sheet.dart';
import 'order_confirmation_screen.dart';

class DashboardSheets {
  static Future<void> showProfileSheet(
    BuildContext context, {
    required String email,
    required VoidCallback onSignOut,
  }) {
    final initial = email.isNotEmpty ? email[0].toUpperCase() : 'U';
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return Container(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 24),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              CircleAvatar(
                radius: 36,
                backgroundColor: theme.colorScheme.primary.withValues(
                  alpha: 0.1,
                ),
                child: Text(
                  initial,
                  style: TextStyle(
                    fontFamily: theme.textTheme.titleLarge?.fontFamily,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Signed in as',
                style: TextStyle(
                  fontSize: 12,
                  color: Color(0xFF4A5568),
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                email,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    onSignOut();
                  },
                  icon: const Icon(
                    Icons.logout_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                  label: const Text(
                    'Sign Out',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFEF4444),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(26),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(26),
                    ),
                  ),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(
                      color: Color(0xFF4A5568),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  static Future<void> showRagSheet(
    BuildContext context, {
    required Function(String) onSubmitted,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return _RagSheetContent(onSubmitted: onSubmitted);
      },
    );
  }

  static Future<CartItemModel?> showItemConfirmSheet(
    BuildContext context, {
    required CartItemModel item,
  }) {
    return showModalBottomSheet<CartItemModel>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return _ItemConfirmSheetContent(item: item);
      },
    );
  }

  static Future<FulfillmentSelection?> showFulfillmentSheet(
    BuildContext context, {
    required double amount,
  }) {
    return showModalBottomSheet<FulfillmentSelection>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return FulfillmentSheet(amount: amount);
      },
    );
  }

  static Future<void> showOrderConfirmationScreen(
    BuildContext context, {
    required FulfillmentSelection fulfillment,
    required double amount,
    required String orderId,
  }) {
    return Navigator.push(
      context,
      MaterialPageRoute(
        builder: (ctx) => OrderConfirmationScreen(
          fulfillment: fulfillment,
          amount: amount,
          orderId: orderId,
        ),
      ),
    );
  }

  static Future<void> showPaymentSheet(
    BuildContext context, {
    required double amount,
    required VoidCallback onPaymentSuccess,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return PaymentSheet(amount: amount, onPaymentSuccess: onPaymentSuccess);
      },
    );
  }

  static Future<void> showMissingRegularsSheet(
    BuildContext context, {
    required List<dynamic> missingItems,
    required VoidCallback onContinueToCheckout,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return MissingRegularsSheet(
          missingItems: missingItems,
          onContinueToCheckout: () {
            // we already popped in the sheet
            onContinueToCheckout();
          },
        );
      },
    );
  }
}

class _RagSheetContent extends StatefulWidget {
  final Function(String) onSubmitted;

  const _RagSheetContent({required this.onSubmitted});

  @override
  State<_RagSheetContent> createState() => _RagSheetContentState();
}

class _RagSheetContentState extends State<_RagSheetContent> {
  final TextEditingController _ragController = TextEditingController();

  @override
  void dispose() {
    _ragController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A1A).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Ask Chef RAG',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ragController,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Ask anything about the products...',
                hintStyle: const TextStyle(color: Color(0xFF4A5568)),
                filled: true,
                fillColor: const Color(0xFFFFFFFF),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: const BorderSide(
                    color: Color(0xFFD2E4E6),
                    width: 1,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: const BorderSide(
                    color: Color(0xFFD2E4E6),
                    width: 1,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(
                    color: theme.colorScheme.secondary,
                    width: 1.5,
                  ),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
              ),
              onSubmitted: (val) {
                if (val.trim().isNotEmpty) {
                  Navigator.pop(context);
                  widget.onSubmitted(val);
                }
              },
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  if (_ragController.text.trim().isNotEmpty) {
                    final text = _ragController.text;
                    Navigator.pop(context);
                    widget.onSubmitted(text);
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(26),
                  ),
                ),
                child: const Text(
                  'Ask',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ItemConfirmSheetContent extends StatefulWidget {
  final CartItemModel item;
  const _ItemConfirmSheetContent({required this.item});

  @override
  State<_ItemConfirmSheetContent> createState() =>
      _ItemConfirmSheetContentState();
}

class _ItemConfirmSheetContentState extends State<_ItemConfirmSheetContent> {
  late double _selectedPrice;

  @override
  void initState() {
    super.initState();
    _selectedPrice = widget.item.price;
  }

  String _getSizeForProduct(String name, String slug, double price) {
    return InventoryService.getSizeForProduct(
      name: name,
      slug: slug,
      price: price,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = widget.item;
    
    final inventoryService = InventoryService();
    final slug = inventoryService.getSlugByName(item.name);
    final localProduct = slug != null ? inventoryService.getProductFromLocal(slug) : null;
    
    final List<dynamic>? pricesRaw = item.prices ?? (localProduct != null ? localProduct['prices'] : null);
    final List<double> prices = pricesRaw != null
        ? pricesRaw.map((e) => (e as num).toDouble()).toList()
        : [];
        
    if (prices.isEmpty) {
      prices.add(item.price);
    } else if (!prices.contains(item.price)) {
      prices.insert(0, item.price);
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(bottom: 20),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Row(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: const Color(0xFFF3F4F6),
                ),
                clipBehavior: Clip.antiAlias,
                child: FutureBuilder<Map<String, dynamic>?>(
                  future: () async {
                    final inventoryService = InventoryService();
                    final slug = inventoryService.getSlugByName(item.name);
                    if (slug != null) {
                      return await inventoryService.getProductBySlug(slug);
                    }
                    return null;
                  }(),
                  builder: (context, snapshot) {
                    String displayUrl = item.imageUrl;
                    if (snapshot.hasData && snapshot.data != null) {
                      final thumbnail =
                          snapshot.data!['thumbnail_url'] as String?;
                      if (thumbnail != null && thumbnail.isNotEmpty) {
                        displayUrl = thumbnail;
                      }
                    }
                    return CachedNetworkImage(
                      imageUrl: displayUrl,
                      fit: BoxFit.cover,
                      placeholder: (context, url) => const Center(
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 1.5),
                        ),
                      ),
                      errorWidget: (context, url, error) =>
                          const Icon(Icons.image, size: 20),
                    );
                  },
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Item detected',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFF4A5568),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.name,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '₹${_selectedPrice.toStringAsFixed(2)}',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (prices.length > 1) ...[
            const SizedBox(height: 16),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Select Variant',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF4A5568),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                child: Row(
                  children: prices.map((p) {
                    final isSelected = p == _selectedPrice;
                    final sizeStr = _getSizeForProduct(item.name, slug ?? '', p);
                    return GestureDetector(
                      onTap: () {
                        setState(() {
                          _selectedPrice = p;
                        });
                      },
                      child: Container(
                        margin: const EdgeInsets.only(right: 12),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? theme.colorScheme.primary.withValues(alpha: 0.05)
                              : Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isSelected
                                ? theme.colorScheme.primary
                                : const Color(0xFFE2E8F0),
                            width: isSelected ? 2 : 1,
                          ),
                          boxShadow: isSelected
                              ? [
                                  BoxShadow(
                                    color: theme.colorScheme.primary.withValues(
                                      alpha: 0.1,
                                    ),
                                    blurRadius: 4,
                                    offset: const Offset(0, 2),
                                  ),
                                ]
                              : null,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              sizeStr,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: isSelected
                                    ? theme.colorScheme.primary
                                    : const Color(0xFF1A202C),
                              ),
                            ),
                            const SizedBox(height: 4),
                             Text(
                               '₹${p.toStringAsFixed(0)}',
                               style: TextStyle(
                                 fontSize: 12,
                                 fontWeight: FontWeight.normal,
                                 color: isSelected
                                     ? theme.colorScheme.primary
                                     : const Color(0xFF718096),
                               ),
                             ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          ],
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () =>
                  Navigator.pop(context, item.copyWith(price: _selectedPrice)),
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(26),
                ),
              ),
              child: const Text(
                'Add to Cart',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () => Navigator.pop(context, null),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(26),
                ),
              ),
              child: const Text(
                'Not this item',
                style: TextStyle(
                  fontSize: 14,
                  color: Color(0xFF4A5568),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
