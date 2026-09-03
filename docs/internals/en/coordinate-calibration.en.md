# Internals · Coordinate Calibration

> Implemented in `CoordinateCapture.swift` (`worldToMapPixel`)
> Up: [Network Localization](../dev/02-network-locate.en.md) ｜ 中文: [坐标标定](../coordinate-calibration.md)

## 1. Problem

The UE5 decoder outputs **game world coordinates** (floating point, centimeter-scale); the collection map needs **11264×11264 map pixel coordinates**. A game-map projection sits between them and must be calibrated.

## 2. Actual transform (worldToMapPixel)

```swift
mapX = kCalibA * wx + kCalibB * wy + kCalibTX
mapY = kCalibA * wy - kCalibB * wx + kCalibTY
```

**This is a linear affine transform**: kCalibB is a **cross-coupling term** (mapX adds `+B·wy`, mapY subtracts `-B·wx`) forming an approximate rotation — not a quadratic term.

## 3. Exact constants

```
kCalibA  = 0.016394586684750773      # primary scale (world units → pixels)
kCalibB  = 5.693519256055879e-08     # cross-coupling (slight axis rotation)
kCalibTX = 6293.474380746091         # X translation
kCalibTY = 3472.664390686138         # Y translation
kNorth   = (-0.013752068070295848, -0.9999054358407049, 0.0)
kEast    = ( 0.9999054358407049, -0.01375206807029585, 0.0)
kMaxLocationAbs = 2_000_000.0        # world-coordinate magnitude cap (cm-scale, not pixels)
```

## 4. Heading mapping (toPose)

World coordinates answer "where"; heading uses dot products with the N/E unit vectors:

```
viewDir = (cos(pitch)cos(yaw), cos(pitch)sin(yaw), sin(pitch))
north = dot(viewDir, kNorth)
east  = dot(viewDir, kEast)
heading = atan2(east, north) × 180/π; negative → +360 → [0, 360)
```

kEast/kNorth carry a ~0.79° slight rotation — the game axes are not perfectly orthogonal to the map.

## 5. Calibration method

1. **Sample**: stand at landmarks in-game; record (a) decoder world coordinates, (b) landmark pixel coordinates on the map
2. **Fit**: least squares for the affine parameters (pure linear first; residual containing a slight rotation → add the cross term and refit)
3. **Validate**: hold out points not used in fitting
4. **Freeze**: constants live in source (map version unchanged → parameters unchanged)

These values are **independently calibrated on this machine**; the methodology comes from MaaNTE but the numbers are not copied verbatim.

## 6. Maintenance

- Changing display resolution / game UI scale: the map's intrinsic 11264×11264 is unchanged — **no recalibration needed**
- A major game update reworking the map: re-sample all points and refit
- Accuracy check: compare `locatorX/Y` against known landmarks while driving; error should stay within single-digit pixels
