# Procreate Replica Specification

Source: official Procreate Handbook (help.procreate.com/procreate/handbook), current as of the app's iPadOS release (referenced version 5.4 with notes on Apple Pencil Pro-era features). This document is written as a build specification: it describes what the app is, how every subsystem behaves, and what data model and architecture would be needed to build a functional clone. It is organized so an engineering team (human or AI agent) can work section by section.

---

## 1. Product Summary

Procreate is a professional raster/vector-hybrid painting application built exclusively for iPadOS, designed around the Apple Pencil and multi-touch gestures. Its defining traits:

- **Minimal chrome, maximal canvas.** The UI is reduced to two thin menu bars (top-left, top-right) and one collapsible sidebar. Everything else is the canvas.
- **Gesture-first interaction.** Nearly every destructive or navigational action (undo, redo, copy/paste, clear, zoom, rotate) has a dedicated multi-touch gesture, so the artist rarely needs to leave the canvas to touch a button.
- **A physically-modeled brush engine.** Brushes are not simple stamps; they are composed of up to 14 independently tunable attributes (shape, grain, rendering, wet mix, dynamics, color dynamics, Apple Pencil response, etc.), enabling everything from a technical pen to a bleeding watercolor wash.
- **Non-destructive layered compositing** with 27+ blend modes, layer masks, clipping masks, alpha lock, and groups.
- **A self-contained file format** (`.procreate`) that stores full layer stacks, brush data, canvas metadata, and optional embedded time-lapse video.
- **Adjacent creative tools bolted onto the same core canvas/layer/brush engine**: vector Text, Drawing Guides (2D/isometric/perspective/symmetry) with Drawing Assist, QuickShape geometric snapping, frame-by-frame Animation Assist, Page Assist (multi-page sketchbook), and 3D model painting.

A replica must therefore be architected around one shared core (canvas + layer stack + brush engine + undo system) with feature modules (selection, transform, adjustments, text, guides, animation, 3D, gallery) all operating on that same core.

---

## 2. Global Interface Layout

The interface has exactly three regions, always in this position (mirrorable left/right via a preference):

### 2.1 Top-right bar — Painting Tools
Left to right: **Paint** (brush icon) · **Smudge** (finger-blob icon) · **Erase** (eraser icon) · **Layers** (two overlapping squares) · **Color** (color-wheel swatch showing current color).

- Single tap on Paint/Smudge/Erase selects that tool.
- Tapping an *already-selected* tool of these three opens the **Brush Library** popover for that tool.
- Tap-and-hold an unselected Paint/Smudge/Erase icon transfers the current brush settings from whichever tool was last active (fast tool-swap without re-picking a brush).
- The Color swatch: tap opens the Color Panel; press-and-hold toggles between current and previous color; drag it onto the canvas to trigger **ColorDrop** (flood fill).

### 2.2 Top-left bar — Editing Tools
Left to right: **Gallery** (chevron/back arrow, returns to the artwork grid) · **Actions** (wrench icon) · **Adjustments** (magic-wand icon) · **Selections** (ribbon/S-curve icon) · **Transform** (arrow-cursor icon).

Each opens its own toolbar/popover system described in later sections.

### 2.3 Left (or right) Sidebar — Modify Controls
A vertical strip containing, top to bottom:
1. **Brush size slider** — drag to resize brush tip; tap anywhere on the track to jump; touch-hold-then-drag-sideways engages a fine-adjustment mode with smaller increments.
2. **Modify button** (square icon, midpoint of sidebar) — default action is Eyedropper (drag to sample color from canvas, or hold + tap with a second finger). Rebindable to any Gesture Control action.
3. **Brush opacity slider** — same interaction model as size.
4. **Undo / Redo arrows** — tap once to step; tap-and-hold to rapid-fire step through history (undo depth: **250 actions**; configurable "Rapid Undo Delay" 0–1.5s).

The sidebar itself is draggable vertically (drag from the screen edge over the Modify button) to reposition it for comfort, and can be hidden entirely via a preference (useful when relying on Hover-based size/opacity gestures instead).

### 2.4 Appearance & Layout Preferences
- **Dark / Light interface** toggle (Dark is default — low-contrast charcoal chrome so it doesn't compete with artwork).
- **Left-hand / Right-hand interface** toggle — mirrors sidebar + tool bar sides.
- **Brush cursor** toggle — shows a live outline of the brush's shape/size wherever the pencil/finger touches (or hovers, if hardware supports Apple Pencil hover).
- **Advanced cursor** settings — cursor visibility (hover / painting / both) and outline style (High Contrast auto-inverting greyscale, Active Color-tinted, or Per-brush custom).
- **Dynamic brush scaling** — keep brush stroke width visually constant in *screen* pixels while zoomed, vs. constant in *canvas* pixels.
- **Full Screen mode** — 4-finger tap hides all chrome; tap again (or the small full-screen indicator, top-left) restores it. Gestures remain fully functional while hidden.
- **Project Canvas** — mirror the canvas only (no UI) to a second display via cable/AirPlay.

---

## 3. Input & Gesture System

This is the interaction backbone; a replica should implement a central gesture recognizer that maps touch-point count + motion pattern → command, with every mapping user-remappable (see §11.4 Gesture Controls).

### 3.1 Canvas navigation
| Gesture | Result |
|---|---|
| 1-finger / Pencil drag on canvas | Paint / Smudge / Erase with active tool |
| 2-finger pinch | Zoom in/out |
| 2-finger pinch + twist | Rotate canvas |
| 2-finger **quick** pinch (fast, short) | Snap to "fit entire canvas to screen"; reverse quick-pinch returns to the prior exact view |
| 2-finger drag | Pan canvas |

### 3.2 History & clipboard
| Gesture | Result |
|---|---|
| 2-finger tap | Undo (hold = rapid repeat) |
| 3-finger tap | Redo (hold = rapid repeat) |
| 3-finger scrub (side-to-side rub) | Clear active layer |
| 3-finger swipe down | Open floating Copy/Paste menu: **Cut, Copy, Copy All, Duplicate, Cut & Paste, Paste** |
| 4-finger tap | Toggle Full Screen (hide/show chrome) |

### 3.3 Shape & precision
| Gesture | Result |
|---|---|
| Draw, then hold pencil/finger in place at stroke end | QuickShape recognizes and snaps the stroke to a straight line, arc, polyline, ellipse, triangle, or polygon |
| While holding a QuickShape, tap with a 2nd finger | Snap to the "perfect" version (square from rectangle, circle from oval, equilateral triangle, etc.) |
| While holding a QuickShape, drag with a 2nd finger touching | Rotate the shape in 15° increments ("magnetic rotate") |
| Grab a slider, then move finger away from it and drag up/down | Enter fine-adjustment mode (smaller increments the further from the origin) |

### 3.4 Layers panel gestures
| Gesture | Result |
|---|---|
| Tap a layer | Select as Primary (only one Primary at a time; highlighted bright blue) |
| Swipe right on a layer | Add as Secondary layer (dark blue; multiple allowed, for group Transform) |
| 2-finger tap a layer | Make Primary + show a draggable opacity readout (drag left/right on canvas to change opacity) |
| 2-finger swipe left→right on a layer | Toggle Alpha Lock |
| 2-finger tap-and-hold a layer | Select the layer's non-transparent content (equivalent to Layer Options → Select) |
| Pinch two layers together | Merge every layer between and including them into one |
| Swipe left on a layer | Reveal Lock / Duplicate / Delete quick-action buttons |
| Tap the Visibility checkbox | Toggle layer visibility |
| Press-and-hold the Visibility checkbox | "Solo visibility" — isolate that one layer; hold again to restore |

### 3.5 Apple Pencil Hover gestures (iPadOS 16.1+, iPad Pro 12.9" 6th-gen / 11" 4th-gen+, Pencil 2 or Pencil Pro)
- Hovering shows a live brush-shape cursor (size, texture, tilt, azimuth preview).
- **Pinch-in-air** (thumb+finger pinch while pencil hovers) — resize brush.
- **Slide left/right while hovering** (or slide up/down with a second finger) — change opacity.
- **Double-tap pencil while hovering over Active Color swatch** — activates hover-ColorDrop: tap canvas locations repeatedly to flood-fill without dragging.

### 3.6 Apple Pencil Pro exclusive gestures
- **Squeeze** — assignable to: trigger QuickShape, invoke QuickMenu, trigger Layer Select, trigger Eyedropper (default system behavior if unassigned mirrors iPadOS pencil settings).
- **Barrel roll** (rotate pencil about its axis) — feeds a new input channel into Brush Studio (Stroke Path jitter, Shape input style, Wet Mix attack, Color Dynamics barrel-roll hue, Apple Pencil barrel-roll size/shape) and can twirl the Liquify adjustment left/right.

### 3.7 Accessibility: Single Touch Gestures Companion
An always-on-top floating panel (toggle in iPadOS Settings → Procreate) with 5 buttons — **Undo, Redo, Zoom, Move, Fit Canvas** — that convert Procreate's default multi-finger gestures into single-finger equivalents (tap-drag-away-from-center to zoom in, tap-drag-toward-center to zoom out, along a visible blue radial guide line; tap-drag to pan; single tap for undo/redo/fit).

### 3.8 QuickMenu (radial menu)
A user-enabled, fully custom 6-button radial menu bound to any gesture (recommended: 1-finger tap for Pencil-only users, or Pencil Pro squeeze). Default bindings: New Layer, Flip Horizontal, Copy, Merge Down, Clear Layer, Flip Vertical. Any of ~59 documented actions (layer ops, tool switches, guide toggles, transform/selection entry, adjustments, etc. — see the Handbook's exhaustive Set Action list) can be bound to any of the 6 slots. Supports unlimited named **QuickMenu Profiles** (e.g. a "Sketching" profile vs a "Coloring" profile), switchable via the menu's center button.

### 3.9 Keyboard shortcuts (hardware keyboard, Windowed-mode menu bar)
Representative bindings a replica should support: ⌘Z/⇧⌘Z undo/redo, ⌘X/⌘C/⌘V cut/copy/paste, ⌘A copy-all, ⌘J duplicate, ⌘D deselect, ⌘⌫ clear, X swap current/previous color, B/E select paint/erase (second press opens brush library), `[`/`]` brush size ±5% (⌘ modifier = ±1%, ⇧ = ±10%), ⌘U HSB adjustment, ⌘B Color Balance, S Selections, V Transform (+arrow keys nudge by 1px while transforming), L Layers panel, C Colors panel, Spacebar QuickMenu, ⌘0 fullscreen toggle, ⌘; toggle Perspective Guide.

---

## 4. Gallery (Project Management / Home Screen)

The Gallery is the app's landing screen: a grid of artwork thumbnails, functioning like a file browser scoped to Procreate documents.

### 4.1 Creating a canvas
Tap **+** → **New Canvas** sheet offering:
- A scrollable list of **preset templates** (Screen Size, Square, 4K, A4, 4×6 Photo, US Letter, etc.), each swipeable to Edit or Delete.
- A **Custom Canvas** screen (tap the "+rectangle" icon) with:
  1. **Name** (tap the title, or Scribble with Pencil).
  2. **Dimensions** — Width, Height, DPI; unit toggle between mm / cm / inches / pixels. Minimum canvas 1×1 px; maximum up to 16K on one axis depending on device RAM. A live "Maximum Layers" readout updates as dimensions change (bigger canvas ⇒ fewer layers, and vice versa — see §6.7 for the formula concept).
  3. **Color Profile** — RGB family (for screens; default **Display P3**) or CMYK family (for print; default **Generic CMYK Profile**); 17 built-in profiles total, plus user-importable ICC profiles.
  4. **Time-lapse settings** — resolution (1080p–4K), quality (Low→Lossless), and an HEVC toggle (enables an alpha channel in the recorded video; requires sRGB color profile).
  5. **Canvas properties** — default background color, or "no background" (transparent) for canvases meant for PNG export.

### 4.2 Preview & browsing
- Tap a thumbnail to open it full-screen.
- Long-press-drag to reorder thumbnails in the grid.
- 2-finger rotate on a thumbnail fixes a sideways/upside-down preview.
- Tap the title beneath a thumbnail to rename ("Untitled Artwork" by default).
- Animated artworks preview their loop directly in the thumbnail.

### 4.3 Organization: Stacks
- Drag one thumbnail onto another to merge them into a **Stack** (a folder, visually a fanned pile of thumbnails).
- Enter Select mode (multi-select via tap or a light swipe across thumbnails) to bulk Share / Duplicate / Delete / Stack.
- Inside a Stack, pick up items and tap the "< Stack" back button to move them out to the top-level Gallery.
- Rename a Stack the same way as an artwork.

### 4.4 Import & Export
- Swipe a thumbnail left → **Share / Duplicate / Delete** (delete is permanent, unrecoverable in-app — but the OS Files "Recently Deleted" can restore brush/file assets).
- Import creates a new canvas automatically sized to the imported image (or, for multi-page PDFs, opens Page Assist).

### 4.5 Supported file types
**Import:** `.procreate`, PSD, JPEG, PNG, TIFF, GIF, PDF, MP4, HEVC, HEIC, OBJ (3D), USDZ (3D). Importing a video renders its frames directly into Animation Assist (frame count capped by the device's max-layer limit).

**Export — flattened/single image:** `.procreate` (native, preserves every layer/mask/blend-mode/effect/time-lapse/signature), PSD (layered, Photoshop-compatible), PDF (Good/Better/Best quality), JPEG (lossy, flattens), PNG (lossless, flattens, preserves transparency), TIFF (flattens, lossless, print-grade).

**Export — per-layer:** multi-page PDF (1 layer = 1 page), folder of individual PNGs (1 layer = 1 file), or an animation (GIF / animated PNG / MP4 / HEVC — 1 layer = 1 frame, visible layers only).

**Export — 3D:** Share Model (OBJ/USDZ), Share Image (image/video of the render), Share Textures (flattened texture maps).

All exports route through the native OS share sheet (AirDrop, Files, Mail, Messages, third-party apps, Print).

---

## 5. Canvas Data Model

A `.procreate` document (or its equivalent in a replica) must model:

```
Artwork
├── metadata
│   ├── title, createdDate, modifiedDate
│   ├── author name, signature (vector strokes), profile picture
│   ├── canvas: pixelWidth, pixelHeight, physicalWidth, physicalHeight, DPI, unit
│   ├── colorProfile (ICC-style, RGB or CMYK family)
│   ├── backgroundColor (or "hidden" for transparency)
│   ├── maxLayers (derived from pixelWidth × pixelHeight × device RAM tier)
│   ├── statistics: totalStrokes, trackedTime, totalFileSizeBytes
│   └── timelapse: enabled, resolution, quality, codec (H.264 / HEVC), recordedFrames[]
├── layerStack (ordered tree — see §6)
├── referenceLayer (flag: which layer, if any, is the ColorDrop ink-line Reference)
├── canvasBackgroundLayer (special always-bottom layer)
├── drawingGuide (type, transform, opacity, color, thickness, drawingAssistEnabled)
├── animation (if Animation Assist used: frame order, per-frame hold-duration, loop settings, onion-skin config)
├── pageAssist (if used: array of page canvases + page order)
├── threeD (if a 3D canvas: mesh reference, UV layers, lighting rig)
└── embeddedBrushes (any custom brushes used, bundled for portability)
```

### 5.1 Layer limit model
Max layer count is inversely proportional to total pixel count and depends on device RAM tier. A replica should implement this as a configurable table (e.g., `maxLayers = floor(deviceMemoryBudgetBytes / (pixelWidth * pixelHeight * bytesPerPixel * safetyFactor))`) rather than a hardcoded constant, and must recompute/display it live during canvas creation and Crop & Resize.

---

## 6. Layers System

### 6.1 Layers panel
A vertically scrolling list, most-recently-added / topmost-composited at the top. Each row shows: thumbnail, name (default "Layer 1", "Layer 2"…, sequential), blend-mode letter badge (default "N" = Normal), visibility checkbox. A special **Background Color** row is pinned at the very bottom (its own solid-color fill or transparency toggle).

### 6.2 Layer Options menu (tap a selected layer again)
Rename · Select (content-based, alpha-driven selection) · Copy · Fill Layer (flood with current color, respects Alpha Lock) · Clear · **Alpha Lock** (restrict painting to already-opaque pixels) · **Mask** (attach a non-destructive greyscale layer mask directly above/bound to the layer — white reveals, black hides, grey = partial) · **Clipping Mask** (clip a layer's visible content to the alpha shape of the layer beneath, independently movable/orderable, unlike a bound Layer Mask) · **Drawing Assist** (bind this layer to the active Drawing Guide) · **Invert** (complementary color inversion) · **Reference** (mark layer as the line-art reference for Reference-aware ColorDrop) · **Merge Down** (destructive combine with the layer below; pinch gesture merges a range at once) · **Combine Down** (non-destructive: wraps into a **Layer Group**).

### 6.3 Layer Groups
A container layer that itself can be renamed, locked, given a blend mode/opacity, masked, or nested. Created via Combine Down or by multi-selecting + grouping. Locking a group locks all its children; unlocking any child unlocks the group.

### 6.4 Locks
- **Layer Lock** — full protection: cannot edit, move, cut, paste, transform, or delete.
- **Alpha Lock** — described above; shows a checkerboard pattern in the thumbnail when active.

### 6.5 Blend Modes (27 total, grouped)
- Normal
- **Darken group:** Multiply, Darken, Shade, Color Burn, Linear Burn, Darker Color
- **Lighten group:** Lighten, Screen, Color Dodge, Add, Lighter Color
- **Contrast group:** Overlay, Soft Light, Hard Light, Vivid Light, Linear Light, Pin Light, Hard Mix
- **Comparative group:** Difference, Exclusion, Subtract, Divide
- **Component group:** Hue, Saturation, Color, Luminosity

Each layer also carries a 0–100% **Opacity** applied on top of its blend mode (adjustable via the Blend Mode popover slider or the 2-finger-tap canvas-drag shortcut).

### 6.6 Layer Sharing/Export
See §4.5 (Share Layers: multi-page PDF, PNG folder, animated GIF/PNG/MP4/HEVC).

---

## 7. Color System

### 7.1 Color Panel — five interchangeable pickers, all sharing one Active Palette footer
1. **Disc** (default) — outer Hue ring + inner zoomable Saturation/Brightness disc with a dual reticle (shows new color vs. most recent History color side by side for comparison). Pinch to zoom the saturation disc for finer picks (auto-resets on panel close). Double-tap on the disc snaps to "pure" values (white, black, mid-gray, full-saturation, half-saturation).
2. **Classic** — traditional H/S/B sliders + a square SV picker.
3. **Harmony** — generates complementary/analogous/triadic-style suggestions from the current color.
4. **Value** — precision sliders plus numeric RGB and hex input fields.
5. **Palettes** — swatch library browser (see §7.3).

Shared elements across all 5 tabs: **Active/Primary/Secondary color swatches** (Secondary feeds Color Dynamics in Brush Studio), a 10-slot **Color History** row, and the currently **Active Palette** strip.

A **Color Companion** mode detaches the panel into a small floating, freely-draggable window (handle-drag from its top edge) that stays on top of the canvas.

### 7.2 Sampling & application tools
- **Eyedropper** — invoke via touch-and-hold on canvas, or the sidebar Modify button (hold, or tap for a floating loupe you drag); shows old/new color split in a loupe. Tapping a second finger while sampling toggles between "sample active layer only" vs "sample the flattened composite."
- **ColorDrop** — drag the Active Color swatch onto the canvas to flood-fill a bounded region; **Threshold** (hold before releasing, then drag left/right on a top bar) controls bleed tolerance (remembers last setting; saves 100% as ~97.6% to avoid overflow); **Continue Filling** mode lets repeated taps flood-fill more regions with the same color without re-dragging; Hover-double-tap variant for Pencil users.
- **SwatchDrop** — identical to ColorDrop but sourced from a palette swatch instead of the Active Color.
- **Recolor** — QuickMenu-only tool: place a crosshair over a color region on the active layer, pick a replacement Active Color, then drag a **Flood** slider to blend the replacement into similar shades with a live preview.

### 7.3 Palettes
- **Swatches** are individual saved colors; **Palettes** are named collections of swatches, viewable **Compact** (10/row) or **Cards** (3/row with editable names).
- Full CRUD: create/duplicate/rename/reorder/delete palettes; the **Active Palette** (checkmark badge) is the one shown across all Color Panel tabs — set active by tapping any swatch inside a non-active palette.
- **Palette Capture** — generate a palette from the iPad camera (Visual mode = colors under the palette reticle only; Indexed mode = broader-contrast sampling across the whole frame), from a Files image, or from a Photos-app image.
- **Import/Export** — drag-and-drop `.swatches` files; import Adobe `.ASE` and `.ACO` palette formats; share via drag-and-drop or the OS share sheet.

### 7.4 Color Profiles
17 built-in ICC-style profiles (RGB screen-oriented and CMYK print-oriented), settable at canvas creation and changeable later (Actions → Canvas → Canvas Information, or Colors → Profiles). User-importable custom profiles.

---

## 8. Brush Engine (Brush Studio)

This is Procreate's most technically distinctive subsystem — a replica's brush engine needs to expose the same conceptual layers so brush *behavior*, not just brush *look*, can be authored.

### 8.1 Mental model
A brush = a **Grain** (bitmap or procedural texture) stamped inside a **Shape** (the stamp's silhouette/mask), dragged along the input path of the stroke. A **Taper** profile shapes the start/end of the stroke (thin→full→thin, mimicking a physical brush lift). **Rendering** settings control blending/glazing behavior of overlapping stamps. **Wet Mix** simulates pigment load and smearing. **Color Dynamics** varies hue/sat/brightness per-stroke or per-stamp. **Dynamics** adds speed-response and jitter/randomness. **Apple Pencil** settings map pressure/tilt/azimuth/barrel-roll to any of the above. **Properties** sets hard limits (min/max size, opacity) and Brush Library thumbnail behavior. **About This Brush** stores name/author/description/signature and a Reset-to-default action.

### 8.2 The 14 Attribute categories (left rail of Brush Studio)
Shape · Grain · Stroke Path · Taper · Rendering · Wet Mix · Color Dynamics · Dynamics · Apple Pencil · Squeeze/Barrel Roll (Pro) · Properties · Materials (for 3D-painting brushes: metallic/roughness maps) · About This Brush · (plus a live-updating **Drawing Pad** preview panel that is not an attribute but always visible).

### 8.3 Editing model
Every numeric setting is slider + tap-to-open a numeric keypad, and most sliders can additionally bind to **Pressure** (an editable 2–6 point curve, x-axis = input pressure, y-axis = output value), **Tilt** (0–90° arc control), or (Apple Pencil Pro) **Barrel Roll** (toggle "Relative to stroke" on/off). The Drawing Pad updates live with every change; it can be cleared (3-finger scrub) and its preview size/preview stroke color changed independently of your actual working canvas.

### 8.4 Brush Library organization
- Two-level hierarchy: **Brush Library → Brush Set → Brush**, now backed 1:1 by the OS file system (`Files → On My iPad|iCloud Drive → Procreate → Brushes`), so renaming/moving/duplicating in Files mirrors into the app and vice versa. File extensions: `.brush` (single brush), `.brushset` (a folder of brushes), `.brushlibrary` (a folder of sets).
- Ships with two default libraries: **Procreate Library** (18 sets: Pencils, Pens, Inks, Markers, Pastels, Oils, Paints, Gouache, Watercolors, Charcoals, Basics, Lettering, Comics, Design, Grunge, Street Art, Digital, Creative) and **Classic Library** (18 sets: Sketching, Drawing, Inking, Painting, Artistic, Calligraphy, Airbrushing, Textures, Abstract, Charcoals, Elements, Spraypaints, Materials, Vintage, Luminance, Industrial, Organic, Water).
- **Recent** (auto-populated, max 8) and **Pinned** brushes float at the top of every set list.
- **Brush Search** (swipe down inside the library view) full-text matches brush/set names across all libraries.
- Full drag-and-drop reorganization: reorder, move vs. copy (drop on a set's title = copy; drop inside a set's brush grid = move) between sets/libraries, multi-item stacks via tap-while-holding.

### 8.5 Dual Brush
A secondary brush texture layered underneath/combined with the primary brush's stamp for compound, organic effects (e.g., a rough grain brush dual-blended with a soft round) — configured from its own attribute pane inside Brush Studio.

### 8.6 Import/Export
Drag a `.brush`/`.brushset`/`.brushlibrary` from Files, or tap an incoming file to trigger an import prompt. Export any brush/set via swipe-left Share or the 3-dot menu, producing the same portable file types.

---

## 9. Paint / Smudge / Erase Tools

All three share one Brush Library and one Brush Studio; the *tool* changes what the stamped stroke does to pixel data:
- **Paint** — lays down pigment; nearly every attribute responds to Apple Pencil pressure/tilt/azimuth/barrel-roll.
- **Smudge** — drags existing pixel color along the stroke path; opacity slider controls smear strength (low = soft blend/gradient, high = wet-paint-like drag with visible streaks).
- **Erase** — subtracts pigment/alpha; opacity slider controls how much alpha is removed per pass (useful for soft fade-outs).

**Brush Size Memory** — up to 4 saved marks per slider (size, opacity), per brush, per tool; tap the "+" in the size/opacity preview popover to pin a mark, tap a mark then "−" to remove it; sliding near a mark snaps to it.

---

## 10. Selections

### 10.1 Modes (bottom toolbar after tapping the Selection button)
- **Automatic** — single-tap flood-select by color/edge similarity; drag to live-adjust the threshold (same UX family as ColorDrop Threshold).
- **Freehand** — draw a fluid lasso, or tap to place polygon vertices (mixable in one selection).
- **Rectangle** / **Ellipse** — drag a bounding shape.

### 10.2 Modifiers (always-available toolbar buttons)
**Add** (union further shapes into the selection; built-in/implicit for Automatic) · **Remove** (subtract) · **Invert** · **Copy & Paste** (duplicates selection to a new "From selection" layer) · **Feather** (0–100% edge softening with live preview) · **Save & Load** (persist named selections for reuse) · **Color Fill** (auto-fill every new selection shape with the Active Color as you draw) · **Clear** (drop the current selection; undoable).

### 10.3 Lifecycle
Drawing a selection shows a marching-ants dotted outline; tapping any other tool **commits** it (masked-out area now renders as semi-transparent diagonal hatching, opacity user-configurable in Preferences); tapping the Selection button again cancels/exits. 2-finger/3-finger undo/redo work mid-draw.

---

## 11. Transform

### 11.1 Entry & bounding box
Tapping Transform auto-selects the active layer's full content inside a dashed bounding box with: **blue transformation nodes** at corners/midpoints (resize), a **green Rotation node** above-center (free rotate, live angle readout), a **yellow Bounding-Box-Adjust node** below-center (re-orient the box itself to match rotated content, without transforming the content), and a numeric **Scale readout**.

### 11.2 Modes
1. **Freeform** — independent X/Y scaling (can distort aspect ratio).
2. **Uniform** — locked aspect ratio scaling.
3. **Distort** — 4-corner independent perspective-style dragging + center-node shear.
4. **Warp** — subdivides the selection into a mesh grid whose nodes (interior and boundary) can each be dragged independently for bends/folds, including folding part of the image back over itself.

### 11.3 Shortcuts
Flip Horizontal / Flip Vertical buttons; Rotate 45° stepper; **Fit to Screen** (two variants: with Magnetics = max-coverage possibly cropping overflow; without = max-size with no cropping, may letterbox); **Snapping** toggle (magnetic alignment guides to canvas center, edges, and other layers' content); **Interpolation** picker — Nearest Neighbor (sharp/jagged), Bilinear (2×2 sample, smoother), Bicubic (4×4 sample, smoothest/softest); **Reset**.

### 11.4 Precision input
Tap a corner/side node's numeric readout to type exact pixel width/height (link/unlink icon toggles Uniform vs Freeform numeric entry); tap the rotation node's readout to type an exact angle (positive = left, negative = right, decimals allowed).

### 11.5 Gestures while transforming
Drag inside/outside the box to move; pinch inside the box to scale uniformly (pinch outside adjusts canvas view instead — inverted by holding the Transform button); tap outside the box to nudge in the drag direction by a zoom-dependent step; two/three-finger tap to undo/redo individual sub-steps if "Simplified Undos" is disabled (otherwise the whole Transform session collapses into one undo step).

---

## 12. Adjustments & Filters

Accessed via the magic-wand icon; split into two families, both applicable either across the **whole Layer** or, in **Pencil** mode, painted on with a brush (Apple-Pencil-only) for localized effect. (Liquify and Clone are Layer-only, no Pencil mode.)

### 12.1 Color Adjustments (4)
- **Hue, Saturation, Brightness** — simple 3-slider global recolor.
- **Color Balance** — separate Shadows/Midtones/Highlights sliders.
- **Curves** — RGB gamma curve editor with histogram overlay.
- **Gradient Map** — remaps image luminance to a chosen (preset or custom) gradient palette.

### 12.2 Filters (11)
- **Gaussian Blur** — even blur, drag to set radius.
- **Motion Blur** — directional streak blur along drag direction.
- **Perspective Blur** — radial (Positional) or directional blur from a draggable focal disc.
- **Noise** — Clouds/Billows/Ridges procedural grain with Scale/Octave/Turbulence controls.
- **Sharpen** — drag to set sharpening amount.
- **Bloom** — glow/light-bleed effect with Transition/Size/Burn controls.
- **Glitch** — 4 sub-types (Artifact, Wave, Signal, Diverge) each independently controllable.
- **Halftone** — Full Color / Screen Print / Newspaper dot-pattern styles, adjustable pattern size.
- **Chromatic Aberration** — Perspective (radial from focal point) or Displacement (horizontal/vertical shift) RGB channel offset.
- **Liquify** — Push/Twirl(-Left/-Right via barrel roll)/Pinch/Expand/Crystals/Edge brush modes with Size/Distortion/Pressure/Momentum controls.
- **Clone** — position a source disc, paint elsewhere to stamp-duplicate that region live.

### 12.3 Adjustments Actions bar (appears on canvas tap while an adjustment is open)
Preview toggle (before/after) · Apply (commit, stay in tool) · Reset (discard changes, stay in tool) · Undo-last-change (stay in tool) · Cancel (discard everything, exit tool).

---

## 13. Text

- **Add** via Actions → Add → Add Text: places a vector "Text" placeholder box in the current color, default font Helvetica Neue.
- Edit via system keyboard or Apple Pencil Scribble (also works for numeric fields app-wide).
- Double-tap the text to open the **Text Entry Companion** (alignment, select-all, cut/copy/paste, font access) → tap the font name (or the "Aa" keyboard-accessory button) to open the full **Edit Style** panel (font family/weight, size, tracking/leading, alignment, underline, outline, capitalization, color).
- The bounding box is independently resizable from its content (drag side nodes to change wrap width; box can extend off-canvas while still vector).
- **Vector vs. Raster**: stays fully editable (retype, restyle, reflow) as vector text; supports move/uniform-transform/opacity/masking/grouping in vector form; must be **Rasterized** (Layer Options → Rasterize) to use Selections, non-uniform Transform, Adjustments, painting on top, or Merge — after which it behaves as a normal pixel layer. Vector text layers show an "A" glyph in their thumbnail and auto-name themselves from their content until manually renamed.

---

## 14. Drawing Guides & Assistance

Enabled via Actions → Canvas → Drawing Guide toggle, configured on a dedicated full-screen **Drawing Guides** editor (Actions → Canvas → Edit Drawing Guide) with a bottom tab bar for guide type:

- **2D Grid** — simple square grid, configurable cell size.
- **Isometric** — 3-axis isometric grid for technical/architectural work.
- **Perspective** — up to 3 adjustable, draggable vanishing points with live horizon-line construction.
- **Symmetry** — Vertical / Horizontal / Quadrant / Radial (8-segment) modes, each with a draggable blue Position node and green Rotation node, and a **Mirrored vs Rotational** toggle (mirror flips the reproduction; rotational spins it 180°).

Shared guide-appearance controls: Color (hue slider), Opacity, Thickness, and a **Drawing Assist** toggle (on by default for Symmetry) that snaps freehand strokes onto the guide's structure — this is a per-layer flag (Layer Options → Drawing Assist) so different layers can be assisted or freehand independently. Cancel/Done buttons commit or discard guide edits.

**QuickShape** (detailed in §3.3) is filed under this same Handbook section since it's the guide-adjacent "instant-perfect-shape" tool: draw+hold → snap → optional Edit Shape mode exposing per-vertex transform nodes for the recognized shape.

---

## 15. Animation Assist

Toggled via Actions → Canvas → Animation Assist. Reinterprets the Layers panel as a horizontal film strip:

- **Timeline** — one frame per layer (or per Layer Group, letting a "frame" contain multiple composited elements); leftmost = bottom of the Layers panel; tap/drag/flick to scrub; current frame underlined in blue.
- **Canvas** shows the current frame at full opacity; **Onion Skinning** (on by default) ghosts neighboring frames semi-transparently for continuity reference, with configurable frame range and opacity/tint.
- **Play/Pause** — live in-app playback loop; tap canvas/timeline to stop.
- **Add Frame** — inserts a blank frame beside the current one.
- **Frame Options** (tap a frame) — Duplicate, Delete, and per-frame **Hold Duration** (frame can persist multiple ticks, for animating on 2s/3s, etc.).
- **Settings** — onion-skin count/opacity, playback FPS, loop mode (loop / ping-pong / once), canvas background handling during export.
- **Share** — export as looping GIF, animated PNG (supports transparency), MP4, or HEVC (transparency-capable); frame timing honors each frame's Hold Duration.

---

## 16. Page Assist

Toggled via Actions → Canvas → Page Assist. Converts the single canvas into a **multi-page sketchbook**: each "page" is an independent full canvas (own layer stack) organized in a page-strip UI analogous to Animation Assist's timeline (add/duplicate/delete/reorder pages, jump via thumbnail strip). Primary use cases: comics/storyboard layout, multi-page sketchbooks, and opening imported multi-page PDFs for markup with all standard Procreate tools per page.

---

## 17. 3D Painting

A separate canvas type (created from the Gallery's New Canvas flow by importing an OBJ or USDZ model, or selecting a 3D preset):

- **Import** — OBJ/USDZ mesh import with material/UV parsing.
- **Basics** — orbit/pan/zoom around the model with modified 2D-style gestures (finger drag orbits by default, or rotates when combined with holding the Modify button, per a Preferences toggle); paint directly onto the UV-mapped surface, with strokes projected onto the mesh in real time.
- **Interface & Gestures** — 3D-specific variants of the standard tool bars; a **Reference Companion** with a dedicated 3D-preview mode.
- **Layers (3D)** — texture-map layers per material slot, plus dedicated **Material** brush attributes (metallic/roughness) available only in this mode.
- **Transform (3D)** — move/rotate/scale the model itself in 3D space, distinct from 2D layer Transform.
- **Lighting Studio** — place/adjust light sources (position, intensity, color, shadow softness) and environment/backdrop before final render.
- **Share** — Share Model (OBJ/USDZ, full mesh+textures), Share Image (still render or video of the model/turntable), Share Textures (flattened 2D texture maps only).

---

## 18. Actions Menu (Wrench Icon)

Six tabs:

### 18.1 Add
Insert a photo/file (Camera, Photos, Files), **Add Text**, **Copy** (whole canvas or current selection to clipboard), **Cut/Paste** shortcuts duplicated here for discoverability.

### 18.2 Canvas
**Crop and Resize** (freeform or aspect-locked drag of a grid overlay, with a Rotation slider, numeric W/H/DPI entry, a live max-layers readout, snapping to canvas edges/centers/content edges, and a **Resample** toggle that scales existing content to fit new numeric dimensions instead of just cropping) · **Animation Assist** toggle · **Page Assist** toggle · **Drawing Guide** toggle + Edit Drawing Guide · **Reference** toggle (floating Reference Companion window showing Canvas / imported Image / live Face-camera feed, each pannable/zoomable, each Eyedropper-sampleable) · **FacePaint** (AR face-tracking canvas mode, TrueDepth/A12-chip+ devices only, wraps a custom canvas onto the user's face live via 4 tracked landmark guides; supports full layers/blend-modes/Animation Assist; export via Take a Photo (3088×2320 JPG) or Record a Video (1080p H.264 MP4), plus a camera-off/background-only mode and a dedicated Full Screen preview) · **Flip Canvas** horizontal/vertical · **Canvas Information** (About-this-artwork signature block: title, author, profile picture, handwritten signature, created/modified timestamps; Dimensions: pixel/physical W×H, DPI; Layers: max/used/available + counts of Assisted/Clipping/Masked/Grouped layers; Color Profile; Video Settings: length/quality/resolution/file-size/codec; Statistics: total strokes, tracked time, total file size).

### 18.3 Share
Full Share Image and Share Layers menus (see §4.5) plus Share 3D when applicable.

### 18.4 Video
Time-lapse recording toggle, playback preview scrubber, export of full-length or condensed (~30s) time-lapse replay.

### 18.5 Prefs (Preferences)
- **Interface**: Dark/Light, Left/Right-hand, Dynamic brush scaling, Project canvas, Brush cursor, Advanced cursor (visibility + outline style), Store brushes in iCloud (with an "All brushes" vs "New brushes only" migration prompt), Rapid Undo Delay slider, Selection mask visibility slider, Size & Opacity sidebar visibility toggle.
- **Pressure and Smoothing**: global Stabilization + Motion Filtering accessibility settings (tremor smoothing), and a customizable **App Pressure Sensitivity** curve (2–6-handle editable curve mapping raw pencil pressure → output value).
- **Gesture Controls** — the full remapping panel, organized into:
  - *Painting Gestures*: Smudge-override, Erase-override, Assisted-Drawing-override triggers (choose which touch/pencil gestures force that behavior regardless of selected tool).
  - *Advanced Feature Gestures*: Eyedropper trigger, QuickShape trigger (+ Pencil Pro squeeze double-trigger for shape-then-perfect), QuickMenu trigger (+ profile cycling).
  - *Full-Screen Gestures*: toggle triggers, plus an "Automatic Full Screen" mode (auto-hides UI on stroke start, auto-restores after an idle delay).
  - *Layer Content Gestures*: Clear Layer trigger (default: 3-finger scrub, exclusive — cannot be reassigned to other functions), Copy & Paste menu trigger, Layer Select trigger (touch-drag or Pencil-Pro-squeeze-and-hover, with a multi-layer disambiguation popup for overlapping content).
  - *Hover*: enable/disable the Apple-Pencil-hover pinch-to-resize and slide-to-opacity gestures.
  - *General*: Disable Touch entirely (gesture-shortcuts-only mode, e.g. for Pencil-exclusive workflows), Disable Undo/Redo taps, Rotate-with-pinch-zoom toggle, Enable 3D painting with finger, Rotate Liquify with Apple Pencil Pro barrel roll.
  - A built-in **Gesture Glossary** documents every named gesture (Tap, Touch, Touch and Hold, Apple Pencil, Apple Pencil double-tap, Modify-Button combos, Draw and Hold, Scrub, Three-finger Swipe, Four-finger Tap) for reference inside the panel itself.
  - Conflict detection: assigning a gesture already bound elsewhere raises a yellow warning icon on the conflicting entry; the system otherwise allows multiple simultaneous bindings to the *same* action.

### 18.6 Help
Latest-features video, support/contact links, community portfolio link, "Learn to Procreate" tutorial links, Restore Purchases, link to iPadOS's per-app Advanced Settings, App Store review prompt.

---

## 19. Accessibility

- **Single Touch Gestures Companion** (see §3.7).
- **Stabilization & Motion Filtering** curves for tremor compensation (Preferences → Pressure and Smoothing).
- Full VoiceOver-compatible control labeling is expected system-wide (standard iPadOS accessibility API usage) though not itemized in the Handbook beyond the above.

---

## 20. Non-Functional / Engineering Requirements

A replica must hit these behavioral guarantees to feel like Procreate rather than a generic paint app:

1. **Undo depth**: minimum 250 steps, cleared on returning to the Gallery (treated as an implicit save/commit point). Transform sessions collapse to 1 undo step by default (togglable to per-sub-step via "Simplified Undos").
2. **Real-time performance**: brush stroke rendering must track Apple-Pencil-class input at full display refresh rate (matching ProMotion 120Hz where available) with zero perceptible latency between physical stroke and rendered mark — this is the single most important perceptual benchmark for the app.
3. **Live-preview everything**: blend modes, adjustments, transforms, guide edits, brush-studio attribute edits all preview at full fidelity before commit, with an explicit Apply/Cancel/Reset step.
4. **Device-scaled capacity limits**: canvas max dimensions and max layer count must be derived from available device memory, not hardcoded, and must be recomputed and surfaced to the user live during canvas creation/resizing.
5. **Autosave-as-you-go**: no explicit "Save" action exists; every stroke persists to the on-device document automatically (the Gallery thumbnail and Canvas Information "Date Modified" reflect this).
6. **Format fidelity**: the native save format must round-trip 100% of layer structure (groups, masks, clipping masks, blend modes, opacity, alpha lock), embedded time-lapse, and canvas metadata (signature, color profile) losslessly. PSD export/import should preserve layers, names, opacity, visibility, and blend modes to the extent PSD's spec allows.
7. **Color management**: all painting, compositing, and adjustment math should occur in the canvas's declared working color profile (RGB or CMYK family), with correct profile-to-profile conversion on export to each target format.

---

## 21. Suggested Reference Architecture for a Clone

For a team actually implementing this (e.g. as a native iPad app or a high-performance web/Metal-backed app):

- **Rendering core**: GPU-accelerated tile-based compositor (Metal/WebGL2/WebGPU) — canvas divided into tiles so only dirty tiles re-render per stroke, keeping frame time bounded regardless of canvas size.
- **Brush engine**: implement as a per-stamp pipeline — (1) sample input state (position, pressure, tilt, azimuth, barrel roll, velocity) → (2) evaluate each bound curve (numeric/pressure/tilt/barrel-roll) per attribute → (3) composite Grain texture through Shape mask at the computed transform → (4) blend into the active layer per Rendering/Wet-Mix/Color-Dynamics rules → (5) accumulate a stroke-level Taper envelope. Expose every stage's parameters as the serializable "brush" data structure so brushes remain fully portable/importable.
- **Layer stack**: a tree (for Groups) of tile-backed bitmap or vector (Text) layers, each with blend mode, opacity, lock flags, and an optional bound Mask layer; composited bottom-up per frame/tile.
- **Undo system**: command-pattern history stack (250-deep ring buffer) storing tile-diffs (not full-canvas snapshots) for memory efficiency; Transform/Selection sessions batch their diffs into a single history entry unless "Simplified Undos" is off.
- **Gesture layer**: a single central multi-touch recognizer emitting semantic events (`undo`, `redo`, `pan`, `zoom`, `rotate`, `quickmenu`, `clearLayer`, …) decoupled from raw touch handling, with a user-editable binding table (mirrors §18.5 Gesture Controls) so every gesture→action mapping is data, not hardcoded logic.
- **File format**: a bundle/archive (zip-like) containing a manifest (JSON/plist: metadata from §5) + one compressed bitmap per layer (or vector data for Text/Guides) + optional embedded video asset for time-lapse + referenced/embedded brush files.
- **Modules as plugins on the shared core**: Selections, Transform, Adjustments, Text, Guides, Animation Assist, Page Assist, and 3D Painting should all be built as independent modules that read/write the same Layer Stack and Undo System rather than forking their own state, since in the real app every one of these tools operates seamlessly on the same document.

---

## 22. Sources

All functional and interaction details above are drawn directly from the official Procreate Handbook: https://help.procreate.com/procreate/handbook (Introduction, Interface & Gestures, Gallery, Colors, Brushes, Layers, Text, Drawing Guides & Assistance, Animation, Page Assist, 3D Painting, Actions, Selections, Transform, and Adjustments sections, version 5.4 with 5.0–5.4 version history noted in-app).
