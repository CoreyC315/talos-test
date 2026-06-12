import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// In production /api is routed to ks-api by the Gateway (same-origin).
// For local dev, proxy /api to a locally running ks-api.
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      '/api': {
        target: 'http://localhost:8080',
        changeOrigin: true,
      },
    },
  },
});
