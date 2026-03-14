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
  late Float32List sourcesBuffer = Float32List(0); // [l, t, r, b]
  late Float32List offsetsBuffer = Float32List(0); // [x, y]
  late Float32List scalesBuffer = Float32List(0);  // [x, y]
  late Float32List anchorsBuffer = Float32List(0); // [x, y]
  late Float32List rotationsBuffer = Float32List(0);
  late Int32List colorsBuffer = Int32List(0);
  late Uint8List visibleBuffer = Uint8List(0);
  late Int32List prioritiesBuffer = Int32List(0);
  late Float32List sortPositionsBuffer = Float32List(0); // [x, y]
  
  // High-performance RST buffers and pivot cache
  late Float32List rstTransformsBuffer = Float32List(0); // [scos, ssin, tx, ty]
  late Float32List rectsBuffer = Float32List(0);        // [l, t, r, b]
  late Float32List pivotsBuffer = Float32List(0);       // [px, py]

  int instanceCount = 0;

  void growBuffers(int required) {
    if (images.length >= required) return;
    final newSize = math.max(required, images.length * 2);
    
    final oldLen = images.length;
    final newImages = List<ui.Image?>.filled(newSize - oldLen, null);
    images.addAll(newImages);

    sourcesBuffer = _copyFloat32(sourcesBuffer, newSize * 4);
    offsetsBuffer = _copyFloat32(offsetsBuffer, newSize * 2);
    scalesBuffer = _copyFloat32(scalesBuffer, newSize * 2);
    anchorsBuffer = _copyFloat32(anchorsBuffer, newSize * 2);
    rotationsBuffer = _copyFloat32(rotationsBuffer, newSize);
    colorsBuffer = _copyInt32(colorsBuffer, newSize);
    visibleBuffer = _copyUint8(visibleBuffer, newSize);
    prioritiesBuffer = _copyInt32(prioritiesBuffer, newSize);
    sortPositionsBuffer = _copyFloat32(sortPositionsBuffer, newSize * 2);
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

  bool _isDirty = false;
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
    int priority = 0,
    Vector2? sortPosition,
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
    );

    _isDirty = true;
    return id;
  }

  void removeInstance(int id) {
    if (id < 0 || id >= instanceCount) return;
    if (images[id] == null) return;

    images[id] = null;
    visibleBuffer[id] = 0;
    freeSlots.add(id);
    _isDirty = true;
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
  ) {
    if (image != null) images[id] = image;

    if (source != null) {
      final sIdx = id * 4;
      sourcesBuffer[sIdx + 0] = source.left;
      sourcesBuffer[sIdx + 1] = source.top;
      sourcesBuffer[sIdx + 2] = source.right;
      sourcesBuffer[sIdx + 3] = source.bottom;
      
      rectsBuffer[sIdx + 0] = source.left;
      rectsBuffer[sIdx + 1] = source.top;
      rectsBuffer[sIdx + 2] = source.right;
      rectsBuffer[sIdx + 3] = source.bottom;
      
      pivotsBuffer[sIdx + 2] = source.width;
      pivotsBuffer[sIdx + 3] = source.height;
    }

    final sIdx = id * 4;
    final w = pivotsBuffer[sIdx + 2];
    final h = pivotsBuffer[sIdx + 3];

    final scos = math.cos(rot) * sclX;
    final ssin = math.sin(rot) * sclX;
    // Note: this assumes uniform scale for rotation math, common in Flame
    // tx = off.x - scos * anc.x * w + ssin * anc.y * h
    final px = scos * ancX * w - ssin * ancY * h;
    final py = ssin * ancX * w + scos * ancY * h;

    pivotsBuffer[sIdx + 0] = px;
    pivotsBuffer[sIdx + 1] = py;

    final rIdx = id * 4;
    rstTransformsBuffer[rIdx + 0] = scos;
    rstTransformsBuffer[rIdx + 1] = ssin;
    rstTransformsBuffer[rIdx + 2] = (offX - px).toDouble();
    rstTransformsBuffer[rIdx + 3] = (offY - py).toDouble();

    final oIdx = id * 2;
    offsetsBuffer[oIdx + 0] = offX;
    offsetsBuffer[oIdx + 1] = offY;
    scalesBuffer[oIdx + 0] = sclX;
    scalesBuffer[oIdx + 1] = sclY;
    anchorsBuffer[oIdx + 0] = ancX;
    anchorsBuffer[oIdx + 1] = ancY;
    sortPositionsBuffer[oIdx + 0] = sortX;
    sortPositionsBuffer[oIdx + 1] = sortY;

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
    int? priority,
    Vector2? sortPosition,
    double? offsetX,
    double? offsetY,
  }) {
    if (id < 0 || id >= instanceCount) return;
    if (images[id] == null) return;

    if (image != null && images[id] != image) {
      images[id] = image;
      _isDirty = true;
    }
    
    if (priority != null && prioritiesBuffer[id] != priority) {
      prioritiesBuffer[id] = priority;
      if (depthSort) _isDirty = true;
    }

    if (isVisible != null) {
      final v = isVisible ? 1 : 0;
      if (visibleBuffer[id] != v) {
        visibleBuffer[id] = v;
        _isDirty = true;
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
        if (depthSort) _isDirty = true;
      }
    }

    // Optimization: if ONLY offset changed, we can avoid trig and full update
    final onlyOffset = source == null && scale == null && anchor == null && rotation == null && color == null;
    
    if (onlyOffset && ox != null && oy != null) {
      final rIdx = id * 4;
      final oIdx = id * 2;
      final pIdx = id * 4;
      offsetsBuffer[oIdx] = ox;
      offsetsBuffer[oIdx + 1] = oy;
      rstTransformsBuffer[rIdx + 2] = ox - pivotsBuffer[pIdx];
      rstTransformsBuffer[rIdx + 3] = oy - pivotsBuffer[pIdx + 1];
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
      );
    }
  }

  void clearInstances() {
    images.fillRange(0, images.length, null);
    visibleBuffer.fillRange(0, visibleBuffer.length, 0);
    instanceCount = 0;
    freeSlots.clear();
    _isDirty = false;
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
    if (_allInstancesSameImage && _singleImage != null && !depthSort && freeSlots.isEmpty && !culling) {
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
        null, null, null, paint,
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
    if (_isDirty || _sortedIndices == null) {
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
          final sortYa = (sortPositionsBuffer[sIdxA + 1] * 1000000.0) + prioritiesBuffer[a];
          final sortYb = (sortPositionsBuffer[sIdxB + 1] * 1000000.0) + prioritiesBuffer[b];

          if (sortYa != sortYb) return sortYa.compareTo(sortYb);

          final sortXa = sortPositionsBuffer[sIdxA];
          final sortXb = sortPositionsBuffer[sIdxB];
          if (sortXa != sortXb) return sortXa.compareTo(sortXb);

          final oIdxA = a * 2;
          final oIdxB = b * 2;
          final oYa = offsetsBuffer[oIdxA + 1];
          final oYb = offsetsBuffer[oIdxB + 1];
          if (oYa != oYb) return oYa.compareTo(oYb);
          return offsetsBuffer[oIdxA].compareTo(offsetsBuffer[oIdxB]);
        });
      }
      _isDirty = false;
    }
  }
}
