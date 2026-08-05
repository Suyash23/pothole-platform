# Architecture Decision Record: Framework Migration

## Context and Problem Statement
The Pothole Finder Web Dashboard needs to display massive amounts of geographic data interactively while adhering to strict performance budgets (FCP < 1.5s, bundle ≤ 250KB) and accessibility compliance (Lighthouse 100, native `<table>` semantics for screen readers). The original dashboard iterations used vanilla JS (Leaflet) and Flutter Web. 

Flutter Web is robust for application logic but introduces a significant initial payload (often > 1.5MB) and renders via a WebGL Canvas or custom DOM structure, which fundamentally degrades accessibility and SEO/semantic value. 

## Decision
We chose to migrate the web dashboard to **React + Vite**, utilizing **MapLibre GL JS** for mapping. 

## Rationale
1. **Performance**: Vite offers extremely fast HMR and optimized production builds via Rollup. React enables lazy loading of non-critical routes (Compare View, City Report) to keep the initial JavaScript payload under 250KB.
2. **Accessibility**: Building with React and Vanilla CSS allows us to write highly semantic HTML, such as native `<table>` elements with `<th scope="col">` and robust `aria-live` regions. This is essential for a 100% Lighthouse Accessibility score.
3. **Map Rendering**: `maplibre-gl` paired with `react-map-gl` provides high-performance vector tile rendering, which is necessary to maintain 60fps when panning across millions of pothole data points.
4. **CSS Control**: Vanilla CSS is used per guidelines to enforce a rigid, aesthetic design system (glassmorphism, curated tokens) without the overhead of utility class libraries.

## Consequences
- We diverge from the mobile app's Flutter codebase, requiring developers to know both Dart and React.
- We achieve the target performance and accessibility budgets.
