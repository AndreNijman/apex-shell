# Material shapes (vendored)

The 35 Material 3 Expressive shapes and the rounded-polygon geometry that
draws them: a QML-compatible JavaScript port of AndroidX's `graphics-shapes`
library (`RoundedPolygon`, `CornerRounding`, `Morph`).

- Source: https://github.com/end-4/rounded-polygon-qmljs
  at commit `e31ec4cb4ebf6a46b267f5c42eabf6874916fa16` (2026-02-15),
  itself a port of https://github.com/Knugel/rounded-polygon-ts, a port of
  AndroidX `androidx.graphics.shapes`.
- Licence: **Apache License 2.0** (`LICENSE` in this directory). The rest of
  Rime Shell is MIT; this directory keeps its own licence.
- Vendored unmodified: `material-shapes.js`, `shapes/`, `geometry/`,
  `graphics/`. Not taken: the upstream `ShapeCanvas.qml` and examples.
- Rime's own code that uses it lives outside this directory
  (`src/shapes/materialpath.js`, `src/components/auth/PasswordShapes.qml`).

To update: copy those files from a newer upstream commit and change the
commit above.
