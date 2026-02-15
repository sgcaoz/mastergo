class EngineCapability {
  const EngineCapability({
    required this.supportedBoardSizes,
    required this.maxConcurrentQueries,
    required this.modelTier,
  });

  final List<int> supportedBoardSizes;
  final int maxConcurrentQueries;
  final String modelTier;
}
