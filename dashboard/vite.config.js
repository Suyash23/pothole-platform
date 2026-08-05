import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  build: {
    chunkSizeWarningLimit: 600,
    rollupOptions: {
      output: {
        manualChunks(id) {
          if (id.includes('node_modules')) {
            // Bundle Firebase separately so it doesn't block initial shell render
            if (id.includes('firebase')) {
              return 'firebase';
            }
            // Bundle React core packages
            if (id.includes('react') || id.includes('scheduler')) {
              return 'react-core';
            }
            // Bundle Lucide icons
            if (id.includes('lucide')) {
              return 'lucide-icons';
            }
            // Keep maplibre isolated
            if (id.includes('maplibre') || id.includes('map-gl')) {
              return 'maplibre-vendor';
            }
            return 'vendor';
          }
        }
      }
    }
  }
})
