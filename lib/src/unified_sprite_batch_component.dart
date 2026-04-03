import 'dart:ui' as ui;
import 'package:flame/components.dart';
import 'package:flame/sprite.dart';
import 'dart:math' as math;
import 'dart:typed_data';

/// An interface for components that can provide a logical position for sorting
/// in a [UnifiedSpriteBatchComponent], even if they are not batched themselves.
abstract interface class HasBatchSortPosition {
  Vector2 getBatchSortPosition();
}

/// A component that renders multiple instances of sprites from a single atlas
/// using [SpriteBatch] for maximum efficiency.
class UnifiedSpriteBatchComponent extends Component with HasGameReference {
  UnifiedSpriteBatchComponent({
    this.blendMode = ui.BlendMode.srcOver,
    this.depthSort = true,
    this.culling = true,
    this.cullingMargin = 200.0,
    ui.ColorFilter? colorFilter,
  }) : _paint = ui.Paint()
         ..colorFilter = colorFilter
         ..isAntiAlias = false
         ..filterQuality = ui.FilterQuality.none;

  final ui.BlendMode blendMode;
  final bool depthSort;
  bool culling;
  final double cullingMargin;
  final ui.Paint _paint;

  ui.ColorFilter? get colorFilter => _paint.colorFilter;
  set colorFilter(ui.ColorFilter? value) => _paint.colorFilter = value;

  final List<ui.Image?> images = [];
  late Float32List offsetsBuffer = Float32List(0); // [x, y]
  late Float32List scalesBuffer = Float32List(0); // [x, y]
  late Float32List anchorsBuffer = Float32List(0); // [x, y]
  late Float32List rotationsBuffer = Float32List(0);
  late Int32List colorsBuffer = Int32List(0);
  late Uint8List visibleBuffer = Uint8List(0);
  late Float64List prioritiesBuffer = Float64List(0);
  late Float32List sortPositionsBuffer = Float32List(0); // [x, y]
  late Float32List spriteOffsetsBuffer = Float32List(0); // [x, y]
  late Float32List logicalSizesBuffer = Float32List(0); // [w, h]

  // High-performance RST buffers and pivot cache
  late Float32List rstTransformsBuffer = Float32List(0); // [scos, ssin, tx, ty]
  late Float32List rectsBuffer = Float32List(0); // [l, t, r, b]
  late Float32List pivotsBuffer = Float32List(0); // [px, py]

  int instanceCount = 0;

  void growBuffers(int required) {
    if (images.length >= required) return;
    final newSize = math.max(required, images.length * 2);

    final oldLen = images.length;
    final newImages = List<ui.Image?>.filled(newSize - oldLen, null);
    images.addAll(newImages);

    offsetsBuffer = _copyFloat32(offsetsBuffer, newSize * 2);
    scalesBuffer = _copyFloat32(scalesBuffer, newSize * 2);
    anchorsBuffer = _copyFloat32(anchorsBuffer, newSize * 2);
    rotationsBuffer = _copyFloat32(rotationsBuffer, newSize);
    colorsBuffer = _copyInt32(colorsBuffer, newSize);
    visibleBuffer = _copyUint8(visibleBuffer, newSize);
    prioritiesBuffer = _copyFloat64(prioritiesBuffer, newSize);
    sortPositionsBuffer = _copyFloat32(sortPositionsBuffer, newSize * 2);
    spriteOffsetsBuffer = _copyFloat32(spriteOffsetsBuffer, newSize * 2);
    logicalSizesBuffer = _copyFloat32(logicalSizesBuffer, newSize * 2);
    rstTransformsBuffer = _copyFloat32(rstTransformsBuffer, newSize * 4);
    rectsBuffer = _copyFloat32(rectsBuffer, newSize * 4);
    pivotsBuffer = _copyFloat32(pivotsBuffer, newSize * 4); // [px, py, w, h]
  }

  Float32List _copyFloat32(Float32List old, int size) {
    final n = Float32List(size);
    n.setRange(0, old.length, old);
    return n;
  }

  Int32List _copyInt32(Int32List old, int size) {
    final n = Int32List(size);
    n.setRange(0, old.length, old);
    return n;
  }

  Float64List _copyFloat64(Float64List old, int size) {
    final n = Float64List(size);
    n.setRange(0, old.length, old);
    return n;
  }

  Uint8List _copyUint8(Uint8List old, int size) {
    final n = Uint8List(size);
    n.setRange(0, old.length, old);
    return n;
  }

  // Reusable buffers for drawRawAtlas final output
  Float32List? _rstOutput;
  Float32List? _rectsOutput;

  void _ensureOutputBuffers(int count) {
    if (_rstOutput == null || _rstOutput!.length < count * 4) {
      _rstOutput = Float32List(count * 4);
      _rectsOutput = Float32List(count * 4);
    }
  }

  int _updateToken = 0;
  int get updateToken => _updateToken;

  int _resetToken = 0;
  int get resetToken => _resetToken;

  bool _isSortDirty = true;
  final List<int> freeSlots = [];
  final List<int> _renderedIndices = [];

  int addInstance({
    required ui.Image image,
    required ui.Rect source,
    required Vector2 offset,
    Vector2? scale,
    Vector2? anchor,
    double rotation = 0.0,
    ui.Color? color,
    double priority = 0,
    Vector2? sortPosition,
    Vector2? spriteOffset,
    Vector2? logicalSize,
    bool isVisible = true,
  }) {
    int id;
    if (freeSlots.isNotEmpty) {
      id = freeSlots.removeLast();
    } else {
      id = instanceCount++;
      growBuffers(instanceCount);
    }

    images[id] = image;
    visibleBuffer[id] = isVisible ? 1 : 0;
    prioritiesBuffer[id] = priority;

    _updateData(
      id,
      image,
      source,
      offset.x,
      offset.y,
      anchor?.x ?? 0.0,
      anchor?.y ?? 0.0,
      scale?.x ?? 1.0,
      scale?.y ?? 1.0,
      rotation,
      color,
      sortPosition?.x ?? offset.x,
      sortPosition?.y ?? offset.y,
      spriteOffset?.x ?? 0.0,
      spriteOffset?.y ?? 0.0,
      logicalSize?.x,
      logicalSize?.y,
    );

    _isSortDirty = true;
    return id;
  }

  void removeInstance(int id) {
    if (id < 0 || id >= instanceCount) return;
    if (images[id] == null) return;

    images[id] = null;
    visibleBuffer[id] = 0;
    freeSlots.add(id);
    _isSortDirty = true;
  }

  void _updateData(
    int id,
    ui.Image? image,
    ui.Rect? source,
    double offX,
    double offY,
    double ancX,
    double ancY,
    double sclX,
    double sclY,
    double rot,
    ui.Color? color,
    double sortX,
    double sortY,
    double sprOffX,
    double sprOffY,
    double? logW,
    double? logH,
  ) {
    if (image != null) images[id] = image;

    final oIdx = id * 2;
    spriteOffsetsBuffer[oIdx + 0] = sprOffX;
    spriteOffsetsBuffer[oIdx + 1] = sprOffY;

    // Store logical size if provided, otherwise default to -1 (means use source dimensions)
    logicalSizesBuffer[oIdx + 0] = logW ?? -1;
    logicalSizesBuffer[oIdx + 1] = logH ?? -1;

    if (source != null) {
      final sIdx = id * 4;
      // Flip logic via source rect coordinates
      double l = source.left;
      double t = source.top;
      double r = source.right;
      double b = source.bottom;

      rectsBuffer[sIdx + 0] = l;
      rectsBuffer[sIdx + 1] = t;
      rectsBuffer[sIdx + 2] = r;
      rectsBuffer[sIdx + 3] = b;

      pivotsBuffer[sIdx + 2] = source.width;
      pivotsBuffer[sIdx + 3] = source.height;
    }

    final sIdx = id * 4;
    final w = pivotsBuffer[sIdx + 2];
    final h = pivotsBuffer[sIdx + 3];

    // Effective logical dimensions for anchor calculation
    final effectiveLogW = logW ?? w;
    final effectiveLogH = logH ?? h;

    // Use absolute scale for RST to avoid uniform inversion issues.
    // Flipping is handled by the rectsBuffer instead.
    final absSclX = sclX.abs();
    final scos = math.cos(rot) * absSclX;
    final ssin = math.sin(rot) * absSclX;

    // Correct pivot logic:
    // Anchor should be relative to LOGICAL frame (effectiveLogW),
    // but the pixels we draw are shifted by sprOffX.
    // So the vector from anchor point to pixels top-left is: (sprOffX - ancX * logW)
    final localX = sprOffX - ancX * effectiveLogW;
    final localY = sprOffY - ancY * effectiveLogH;

    final px = scos * localX - ssin * localY;
    final py = ssin * localX + scos * localY;

    pivotsBuffer[sIdx + 0] = px; // Combined transformed local offset
    pivotsBuffer[sIdx + 1] = py;

    final rIdx = id * 4;
    rstTransformsBuffer[rIdx + 0] = scos;
    rstTransformsBuffer[rIdx + 1] = ssin;
    rstTransformsBuffer[rIdx + 2] = (offX + px).toDouble();
    rstTransformsBuffer[rIdx + 3] = (offY + py).toDouble();

    final oIdx2 = id * 2;
    offsetsBuffer[oIdx2 + 0] = offX;
    offsetsBuffer[oIdx2 + 1] = offY;
    scalesBuffer[oIdx2 + 0] = sclX;
    scalesBuffer[oIdx2 + 1] = sclY;
    anchorsBuffer[oIdx2 + 0] = ancX;
    anchorsBuffer[oIdx2 + 1] = ancY;
    sortPositionsBuffer[oIdx2 + 0] = sortX;
    sortPositionsBuffer[oIdx2 + 1] = sortY;

    rotationsBuffer[id] = rot;
    if (color != null) colorsBuffer[id] = color.value;
  }

  void updateInstance(
    int id, {
    ui.Image? image,
    ui.Rect? source,
    Vector2? offset,
    Vector2? scale,
    Vector2? anchor,
    double? rotation,
    ui.Color? color,
    bool? isVisible,
    double? priority,
    Vector2? sortPosition,
    double? offsetX,
    double? offsetY,
    Vector2? spriteOffset,
    Vector2? logicalSize,
    bool flipX = false,
    bool flipY = false,
  }) {
    if (id < 0 || id >= instanceCount) return;
    if (images[id] == null) return;

    if (image != null && images[id] != image) {
      images[id] = image;
      _isSortDirty = true;
    }

    if (priority != null && prioritiesBuffer[id] != priority) {
      prioritiesBuffer[id] = priority;
      if (depthSort) _isSortDirty = true;
    }

    if (isVisible != null) {
      final v = isVisible ? 1 : 0;
      if (visibleBuffer[id] != v) {
        visibleBuffer[id] = v;
        _isSortDirty = true;
      }
    }

    final ox = offsetX ?? offset?.x;
    final oy = offsetY ?? offset?.y;

    if (sortPosition != null) {
      final sIdx = id * 2;
      if (sortPositionsBuffer[sIdx] != sortPosition.x ||
          sortPositionsBuffer[sIdx + 1] != sortPosition.y) {
        sortPositionsBuffer[sIdx] = sortPosition.x;
        sortPositionsBuffer[sIdx + 1] = sortPosition.y;
        if (depthSort) _isSortDirty = true;
      }
    }

    // Optimization: if ONLY offset changed, we can avoid trig and full update
    final onlyOffset =
        source == null &&
        scale == null &&
        anchor == null &&
        rotation == null &&
        color == null &&
        spriteOffset == null &&
        logicalSize == null &&
        !flipX &&
        !flipY;

    if (onlyOffset && ox != null && oy != null) {
      final oIdx = id * 2;
      if (offsetsBuffer[oIdx] == ox && offsetsBuffer[oIdx + 1] == oy) return;

      final rIdx = id * 4;
      final pIdx = id * 4;
      offsetsBuffer[oIdx] = ox;
      offsetsBuffer[oIdx + 1] = oy;
      rstTransformsBuffer[rIdx + 2] = ox + pivotsBuffer[pIdx];
      rstTransformsBuffer[rIdx + 3] = oy + pivotsBuffer[pIdx + 1];
    } else {
      _updateData(
        id,
        image,
        source,
        ox ?? offsetsBuffer[id * 2],
        oy ?? offsetsBuffer[id * 2 + 1],
        anchor?.x ?? anchorsBuffer[id * 2],
        anchor?.y ?? anchorsBuffer[id * 2 + 1],
        scale?.x ?? scalesBuffer[id * 2],
        scale?.y ?? scalesBuffer[id * 2 + 1],
        rotation ?? rotationsBuffer[id],
        color,
        sortPosition?.x ?? sortPositionsBuffer[id * 2],
        sortPosition?.y ?? sortPositionsBuffer[id * 2 + 1],
        spriteOffset?.x ?? spriteOffsetsBuffer[id * 2],
        spriteOffset?.y ?? spriteOffsetsBuffer[id * 2 + 1],
        logicalSize?.x ??
            (logicalSizesBuffer[id * 2] >= 0
                ? logicalSizesBuffer[id * 2]
                : null),
        logicalSize?.y ??
            (logicalSizesBuffer[id * 2 + 1] >= 0
                ? logicalSizesBuffer[id * 2 + 1]
                : null),
      );
    }
  }

  void clearInstances() {
    images.fillRange(0, images.length, null);
    visibleBuffer.fillRange(0, visibleBuffer.length, 0);
    instanceCount = 0;
    freeSlots.clear();
    _isSortDirty = false;
    _resetToken++;
  }

  @override
  void update(double dt) {
    _updateToken++;
    super.update(dt);
  }

  @override
  void render(ui.Canvas canvas) {
    if (instanceCount == 0) return;

    _rebuildIfNeeded();

    // Fast Path: Single Image, No Sorting, No Holes, No Culling
    if (_allInstancesSameImage &&
        _singleImage != null &&
        !depthSort &&
        freeSlots.isEmpty &&
        !culling) {
      canvas.drawRawAtlas(
        _singleImage!,
        rstTransformsBuffer.buffer.asFloat32List(0, instanceCount * 4),
        rectsBuffer.buffer.asFloat32List(0, instanceCount * 4),
        null,
        null,
        null,
        _paint,
      );
      return;
    }

    final paint = _paint;
    if (colorFilter != null) paint.colorFilter = colorFilter;

    // Instead, we render "runs" of consecutive instances with the same image.
    final indices = _sortedIndices;
    if (indices == null) return;

    ui.Rect? visibleRect;
    if (culling) {
      try {
        final g = game;
        visibleRect = (g as dynamic).camera.visibleWorldRect.inflate(
          cullingMargin,
        );
      } catch (_) {}
    }

    // Step 1: Filter indices based on visibility and culling
    _renderedIndices.clear();
    for (final i in indices) {
      if (visibleBuffer[i] == 0) continue;

      if (visibleRect != null) {
        final oIdx = i * 2;
        final sIdx = i * 4;
        final offX = offsetsBuffer[oIdx];
        final offY = offsetsBuffer[oIdx + 1];

        // Accurate bounds check using cached sizes
        final w = pivotsBuffer[sIdx + 2] * scalesBuffer[oIdx].abs();
        final h = pivotsBuffer[sIdx + 3] * scalesBuffer[oIdx + 1].abs();

        if (offX + w < visibleRect.left ||
            offX - w > visibleRect.right ||
            offY + h < visibleRect.top ||
            offY - h > visibleRect.bottom) {
          continue;
        }
      }
      _renderedIndices.add(i);
    }

    if (_renderedIndices.isEmpty) return;

    // Fast Path 2: Single image, culling on, but we've already filtered
    if (_allInstancesSameImage && _singleImage != null && !depthSort) {
      final runCount = _renderedIndices.length;
      _ensureOutputBuffers(runCount);

      final outRst = _rstOutput!;
      final outRects = _rectsOutput!;

      for (var j = 0; j < runCount; j++) {
        final idx = _renderedIndices[j];
        final rIdx = idx * 4;
        final outIdx = j * 4;
        outRst[outIdx] = rstTransformsBuffer[rIdx];
        outRst[outIdx + 1] = rstTransformsBuffer[rIdx + 1];
        outRst[outIdx + 2] = rstTransformsBuffer[rIdx + 2];
        outRst[outIdx + 3] = rstTransformsBuffer[rIdx + 3];
        outRects[outIdx] = rectsBuffer[rIdx];
        outRects[outIdx + 1] = rectsBuffer[rIdx + 1];
        outRects[outIdx + 2] = rectsBuffer[rIdx + 2];
        outRects[outIdx + 3] = rectsBuffer[rIdx + 3];
      }

      canvas.drawRawAtlas(
        _singleImage!,
        outRst.buffer.asFloat32List(0, runCount * 4),
        outRects.buffer.asFloat32List(0, runCount * 4),
        null,
        null,
        null,
        paint,
      );
      return;
    }

    ui.Image? currentImage;
    int runStart = 0;

    void flush(int end) {
      if (currentImage == null || runStart >= end) return;

      final runCount = end - runStart;
      _ensureOutputBuffers(runCount);

      final outRst = _rstOutput!;
      final outRects = _rectsOutput!;

      for (var j = 0; j < runCount; j++) {
        final idx = _renderedIndices[runStart + j];

        final rIdx = idx * 4;
        final outIdx = j * 4;

        outRst[outIdx + 0] = rstTransformsBuffer[rIdx + 0];
        outRst[outIdx + 1] = rstTransformsBuffer[rIdx + 1];
        outRst[outIdx + 2] = rstTransformsBuffer[rIdx + 2];
        outRst[outIdx + 3] = rstTransformsBuffer[rIdx + 3];

        outRects[outIdx + 0] = rectsBuffer[rIdx + 0];
        outRects[outIdx + 1] = rectsBuffer[rIdx + 1];
        outRects[outIdx + 2] = rectsBuffer[rIdx + 2];
        outRects[outIdx + 3] = rectsBuffer[rIdx + 3];
      }

      canvas.drawRawAtlas(
        currentImage,
        outRst.buffer.asFloat32List(0, runCount * 4),
        outRects.buffer.asFloat32List(0, runCount * 4),
        null, // FAST: No colors per-sprite
        null,
        null,
        paint,
      );
    }

    for (var i = 0; i < _renderedIndices.length; i++) {
      final idx = _renderedIndices[i];
      final img = images[idx];
      if (img != currentImage) {
        flush(i);
        currentImage = img;
        runStart = i;
      }
    }
    flush(_renderedIndices.length);
  }

  List<int>? _sortedIndices;

  ui.Image? _singleImage;
  bool _allInstancesSameImage = false;

  void _rebuildIfNeeded() {
    if (_isSortDirty || _sortedIndices == null) {
      final activeIndices = <int>[];
      ui.Image? firstImage;
      bool same = true;

      for (var i = 0; i < instanceCount; i++) {
        final img = images[i];
        if (img != null) {
          activeIndices.add(i);
          if (firstImage == null) {
            firstImage = img;
          } else if (img != firstImage) {
            same = false;
          }
        }
      }

      _singleImage = firstImage;
      _allInstancesSameImage = same;
      _sortedIndices = activeIndices;
      if (depthSort) {
        _sortedIndices!.sort((a, b) {
          final sIdxA = a * 2;
          final sIdxB = b * 2;
          final sortYa = sortPositionsBuffer[sIdxA + 1];
          final sortYb = sortPositionsBuffer[sIdxB + 1];
          // Primary Sort: Isometric Row (Y coordinate)
          if (sortYa != sortYb) return sortYa.compareTo(sortYb);

          final pA = prioritiesBuffer[a];
          final pB = prioritiesBuffer[b];
          // Secondary Sort: Layer Priority within the same row
          if (pA != pB) return pA.compareTo(pB);

          final sortXa = sortPositionsBuffer[sIdxA];
          final sortXb = sortPositionsBuffer[sIdxB];
          // Tertiary Sort: Left-to-right within the same row
          if (sortXa != sortXb) return sortXa.compareTo(sortXb);

          // Final tie-breaker: Stable sorting by instance ID (addition order)
          return a.compareTo(b);
        });
      }
      _isSortDirty = false;
    }
  }
}
