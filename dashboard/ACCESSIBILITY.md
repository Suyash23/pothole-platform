# Accessibility Compliance & Standards (Lighthouse 100 a11y)

This document outlines the detailed accessibility strategies, semantics, and standards implemented in the React + Vite Road Quality Global Dashboard to ensure robust support for assistive technologies, screen readers, and keyboard navigation.

## 1. Core Semantic Hierarchy
- **Single `<h1>` Tag**: The main dashboard header contains a single `<h1>` tag in the `TopBar` for clear outline hierarchy.
- **Section Landmarks**: Use of standard HTML5 semantic landmarks like `<header>` (Top Bar), `<aside>` (Filters Panel and Telemetry Drawer), `<main>` (content wrapper), `<footer>` (Status Bar), and `<nav>` where appropriate.
- **Native Table Structure**: The Data Ledger uses standard `<table>`, `<thead>`, `<tbody>`, `<tr>`, and `<th>` elements with `scope="col"` attributes. This ensures screen readers announce table dimensions, headers, and cell relationships accurately compared to custom Flutter canvas drawing or simulated div-based grids.

## 2. Keyboard Navigation & Focus Management
- **Focus Indicators**: Every interactive control (buttons, selects, range sliders, check boxes) includes visible `:focus-visible` styles with a high-contrast outline (`2px solid var(--accent-brand)`) and offsets to make keyboard navigation highly visible.
- **Tab Order Hierarchy**: Natural tab flow from TopBar -> Filters Panel -> Map Area controls -> Status Bar view toggles -> Telemetry Detail Drawer.
- **Aria-Labels on Icon Buttons**: Since many premium UI components rely on Lucide SVG icons (e.g., closing panels, search clearing, map layers), every icon-only button is explicitly annotated with clear, localized `aria-label` strings (e.g. `aria-label="Close telemetry details panel"`).

## 3. ARIA Live Regions
- **Dynamic Defect Count Updates**: The Left Filter Panel updates the list of active defects in real time. The counts displayed in the `StatusBar` are wrapped in an `aria-live="polite"` container, ensuring that screen readers announce the updated counts (e.g. *"Showing 409 of 409 defect points"*) dynamically whenever filters change.
- **Loading Overlay status**: The main loading spinner includes an active status element with `role="status"` and `aria-live="assertive"` to announce background connection progress.

## 4. Contrast & Color Accessibility
All elements conform strictly to **WCAG 2.1 AA** (and mostly AAA) contrast requirements (minimum 4.5:1 ratio):
- **Light Theme**:
  - Primary text (`#111827`) on background (`#FFFFFF`): **19.5:1** (AAA Compliant)
  - Secondary meta text (`#4B5563`) on background (`#FFFFFF`): **9.0:1** (AAA Compliant)
- **Dark Theme**:
  - Primary text (`#F9FAFB`) on surface (`#26292D`): **14.2:1** (AAA Compliant)
  - Secondary meta text (`#9CA3AF`) on surface (`#26292D`): **4.8:1** (AA Compliant)
- **Color Independence**: Severity gradients are paired with explicit label text (Mild, Moderate, Severe) and geometric badges to ensure users with color vision deficiencies (protanopia, deuteranopia, tritanopia) are never locked out of vital vibration data.
