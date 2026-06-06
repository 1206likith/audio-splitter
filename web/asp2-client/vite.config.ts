import { defineConfig } from 'vite';
import { VitePWA } from 'vite-plugin-pwa';

// Audio Splitter v2 web client build. PWA so a phone browser can "install" the
// listener and keep a service-worker cache for offline reconnects.
export default defineConfig({
  plugins: [
    VitePWA({
      registerType: 'autoUpdate',
      manifest: {
        name: 'Audio Splitter',
        short_name: 'Splitter',
        start_url: '/',
        display: 'standalone',
        background_color: '#0b0b10',
        theme_color: '#0b0b10',
      },
    }),
  ],
  test: {
    globals: true,
    environment: 'node',
  },
});
