import 'dart:ui' as ui;
import 'package:flame/components.dart';
import 'package:flame_texturepacker/flame_texturepacker.dart';
import 'unified_sprite_batch_component.dart';

/// A mixin for [PositionComponent]s that want to delegate their rendering
/// to a [UnifiedSpriteBatchComponent].
mixin UnifiedBatchChildMixin on PositionComponent, HasPaint {
  UnifiedSpriteBatchComponent? _batchParent;
  int? _instanceId;
  int _lastResetToken = -1;

  /// Whether this component should skip its update cycle when off-screen.
  bool batchCulling = true;

  /// Whether this component is allowed to be rendered via the batch.
  /// If false, it will fall back to standard Flame rendering (allowing decorators).
  bool _isBatchingEnabled = true;
  bool get isBatchingEnabled => _isBatchingEnabled;
  set isBatchingEnabled(bool value) {
    if (_isBatchingEnabled == value) return;
    _isBatchingEnabled = value;
    if (!_isBatchingEnabled) {
      final parent = _batchParent;
      final id = _instanceId;
      if (parent != null && id != null) {
        parent.removeInstance(id);
      }
      _instanceId = null;
    }
  }

  // Static frame cache to avoid redundant visibility checks across 10k+ components
  static int _lastFrameTick = -1;
  static ui.Rect? _cachedVisibleRect;
  bool isVisible = true;

  /// Optional override for sorting position. If null, uses [getBatchSortPosition].
  Vector2? batchSortPosition;

  /// Optional relative priority offset within the batch.
  /// Adding 0.1 to a turret ensures it stays above a base with the same integer priority.
  double batchSubPriority = 0.0;

  /// Whether the properties of this sprite (source, scale, image) are static.
  /// If true, some per-frame checks are skipped.
  bool batchStatic = false;

  // Cached properties to avoid redundant getter calls and logic
  ui.Rect? _lastSource;
  ui.Image? _lastImage;
  Vector2? _lastScale;
  Vector2? _lastSortPos;
  double _lastRotation = -1000.0;
  final Vector2 _lastOffset = Vector2.zero();

  /// Registers this component with a [UnifiedSpriteBatchComponent].
  void registerWithBatch(
    UnifiedSpriteBatchComponent parent, {
    ui.Rect? source,
  }) {
    if (_instanceId != null &&
        _batchParent == parent &&
        _lastResetToken == parent.resetToken) {
      return; // Already registered and batch wasn't reset
    }

    _batchParent = parent;

    final img = _getCurrentImage() ?? _getFallbackImage();
    if (img == null) return; // Wait for next update if no image at all

    final src = source ?? _getCurrentSource();
    if (src == null) return;

    final scl = _getBatchScale(src);
    // Detection of non-uniform scaling (unsupported by RST transforms used in drawRawAtlas)
    if ((scl.x - scl.y).abs() > 0.001) {
      // Fallback: don't register, use standard rendering
      return;
    }

    final sortPos = getBatchSortPosition();

    _instanceId = parent.addInstance(
      image: img,
      source: src,
      offset: absolutePosition,
      anchor: anchor.toVector2(),
      scale: scl,
      rotation: absoluteAngle,
      color: (this as HasPaint).paint.color,
      priority: (priority + batchSubPriority)
          .toDouble(), // Use standard priority + sub-priority
      sortPosition: sortPos,
      spriteOffset: getSpriteOffset(),
      logicalSize: getSpriteOriginalSize(),
    );
    _lastResetToken = parent.resetToken;
  }

  ui.Image? _getFallbackImage() {
    try {
      if (this is SpriteComponent)
        return (this as SpriteComponent).sprite?.image;
      if (this is SpriteAnimationComponent) {
        return (this as SpriteAnimationComponent)
            .animation
            ?.frames
            .first
            .sprite
            .image;
      }
    } catch (_) {}
    return null;
  }

  @override
  void onMount() {
    super.onMount();
    _updateBatch();
  }

  @override
  void update(double dt) {
    bool needsRegistration =
        isBatchingEnabled &&
        (_instanceId == null ||
            (_batchParent != null &&
                _lastResetToken != _batchParent!.resetToken));

    if (needsRegistration && _batchParent != null) {
      registerWithBatch(_batchParent!);
    }

    if (batchCulling) {
      final batch = _batchParent;
      if (batch != null && batch.culling) {
        isVisible = _checkVisibility(batch);
        if (!isVisible) {
          _updateBatch(); // Sync the isVisible flag even if we don't update animations
          return;
        }
      }
    }

    super.update(dt);
    _updateBatch();
  }

  /// Whether this component is currently being rendered via the batch parent.
  bool get isBatched => _instanceId != null;

  bool _checkVisibility(UnifiedSpriteBatchComponent batch) {
    // Use the batch's own update token as a reliable per-frame identifier
    final currentTick = batch.updateToken;
    if (currentTick != _lastFrameTick) {
      _lastFrameTick = currentTick;
      try {
        final game = batch.game;
        _cachedVisibleRect = (game as dynamic).camera.visibleWorldRect.inflate(
          batch.cullingMargin,
        );
      } catch (_) {
        _cachedVisibleRect = null;
      }
    }

    final rect = _cachedVisibleRect;
    if (rect == null) return true;

    // Fast bounds check
    final pos = absolutePosition;
    final s = size;
    // Note: this is a simplification (ignores rotation/anchor) but good enough for culling
    if (pos.x + s.x < rect.left ||
        pos.x > rect.right ||
        pos.y + s.y < rect.top ||
        pos.y > rect.bottom) {
      return false;
    }
    return true;
  }

  void _updateBatch() {
    final parent = _batchParent;
    final id = _instanceId;
    if (parent == null || id == null) return;

    final curOffset = absolutePosition;
    final curRotation = absoluteAngle;

    // Fast check for movement
    final moved =
        _lastOffset.x != curOffset.x ||
        _lastOffset.y != curOffset.y ||
        _lastRotation != curRotation;

    if (!moved && batchStatic && isVisible) return;

    ui.Image? img;
    ui.Rect? src;
    Vector2? scl;
    Vector2? sortPos;
    Vector2? sprOff;

    if (!batchStatic || _lastSource == null) {
      img = _getCurrentImage();
      src = _getCurrentSource();
      if (src == null) return;
      scl = _getBatchScale(src);

      // Detection of non-uniform scaling (unsupported by RST transforms)
      if ((scl.x - scl.y).abs() > 0.001) {
        // Fallback: unregister and use standard rendering
        parent.removeInstance(id);
        _instanceId = null;
        return;
      }

      _lastImage = img;
      _lastSource = src;
      _lastScale = scl;
    } else {
      img = _lastImage;
      src = _lastSource;
      scl = _lastScale;
    }

    if (parent.depthSort) {
      sortPos = getBatchSortPosition();
    }

    sprOff = getSpriteOffset();

    parent.updateInstance(
      id,
      image: img,
      source: src,
      offsetX: curOffset.x,
      offsetY: curOffset.y,
      scale: scl,
      rotation: curRotation,
      color: (this as HasPaint).paint.color,
      isVisible: isVisible,
      priority: (priority + batchSubPriority).toDouble(),
      sortPosition: sortPos,
      spriteOffset: sprOff,
      logicalSize: getSpriteOriginalSize(),
      // Note: anchor changes are rare, we don't pass them every frame to avoid anchor.toVector2()
    );

    _lastOffset.setFrom(curOffset);
    _lastRotation = curRotation;
  }

  ui.Rect? _getCurrentSource() {
    Sprite? sprite;
    if (this is SpriteAnimationComponent) {
      final ticker = (this as SpriteAnimationComponent).animationTicker;
      if (ticker != null) sprite = ticker.getSprite();
    } else if (this is SpriteComponent) {
      sprite = (this as SpriteComponent).sprite;
    }

    if (sprite == null) return null;

    if (sprite is TexturePackerSprite) {
      final region = sprite.region;
      // For drawRawAtlas, we must use the actual texel rect.
      return ui.Rect.fromLTWH(
        region.left,
        region.top,
        region.width,
        region.height,
      );
    }
    return sprite.src;
  }

  ui.Image? _getCurrentImage() {
    if (this is SpriteAnimationComponent) {
      final ticker = (this as SpriteAnimationComponent).animationTicker;
      if (ticker == null) return null;
      return ticker.getSprite().image;
    } else if (this is SpriteComponent) {
      return (this as SpriteComponent).sprite?.image;
    }
    return null;
  }

  /// Returns the internal offset of the current sprite (e.g. from an atlas).
  /// Subclasses should override this if they use [TexturePackerSprite].
  Vector2 getSpriteOffset() => Vector2.zero();

  /// Returns the original (logical) size of the sprite before trimming.
  /// Subclasses should override this if they use [TexturePackerSprite].
  /// Defaults to the current source rect size if not overridden.
  Vector2 getSpriteOriginalSize() {
    Sprite? sprite;
    if (this is SpriteAnimationComponent) {
      final ticker = (this as SpriteAnimationComponent).animationTicker;
      if (ticker != null) sprite = ticker.getSprite();
    } else if (this is SpriteComponent) {
      sprite = (this as SpriteComponent).sprite;
    }

    if (sprite is TexturePackerSprite) {
      final r = sprite.region;
      return Vector2(r.originalWidth.toDouble(), r.originalHeight.toDouble());
    }

    final src = _getCurrentSource();
    if (src == null) return size;
    return Vector2(src.width, src.height);
  }

  /// Returns the logical position used for sorting in the batch.
  /// Defaults to searching for [HasBatchSortPosition] in parents,
  /// then falling back to world position ([absolutePosition]).
  /// Override this to provide grid coordinates for exact sorting.
  Vector2 getBatchSortPosition() {
    if (batchSortPosition != null) return batchSortPosition!;
    if (batchStatic && _lastSortPos != null) return _lastSortPos!;

    // Default to bottom-center of the component (the "feet") for robust Z-sorting
    final pos = absolutePosition;
    _lastSortPos ??= Vector2.zero();
    _lastSortPos!.setValues(
      pos.x + size.x * (0.5 - anchor.x) * absoluteScale.x,
      pos.y + size.y * (1.0 - anchor.y) * absoluteScale.y,
    );
    return _lastSortPos!;
  }

  Vector2 _getBatchScale(ui.Rect? source) {
    if (source == null || source.width == 0) return absoluteScale;
    // Batch scale should account for the size difference between the logical frame
    // and the component size.
    final orig = getSpriteOriginalSize();
    final baseScale = size.x / orig.x;
    return Vector2(baseScale * absoluteScale.x, baseScale * absoluteScale.y);
  }

  @override
  void onRemove() {
    final parent = _batchParent;
    final id = _instanceId;
    if (parent != null && id != null) {
      parent.removeInstance(id);
    }
    _instanceId = null;
    super.onRemove();
  }

  @override
  void render(ui.Canvas canvas) {
    if (isBatched && isBatchingEnabled) {
      // The component's own visuals (like Sprite or Animation) are handled by the batch parent.
      return;
    }
    super.render(canvas);
  }
}
