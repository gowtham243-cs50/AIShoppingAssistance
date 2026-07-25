enum FulfillmentType {
  counterPickup,
  parkingPickup,
  homeDelivery,
}

class FulfillmentLocationOption {
  final String id;
  final String title;
  final String subtitle;
  final String estimatedTime;
  final String iconName;

  const FulfillmentLocationOption({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.estimatedTime,
    required this.iconName,
  });
}

class FulfillmentSelection {
  final FulfillmentType type;
  final String title;
  final String subtitle;
  final String estimatedTime;
  final String? vehicleOrAddressDetail;

  const FulfillmentSelection({
    required this.type,
    required this.title,
    required this.subtitle,
    required this.estimatedTime,
    this.vehicleOrAddressDetail,
  });

  String get typeLabel {
    switch (type) {
      case FulfillmentType.counterPickup:
        return 'In-Store Counter Pickup';
      case FulfillmentType.parkingPickup:
        return 'Parking Bay Pickup';
      case FulfillmentType.homeDelivery:
        return 'Home Doorstep Delivery';
    }
  }
}
