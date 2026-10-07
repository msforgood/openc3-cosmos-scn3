// Tool build convention derived from OpenC3 6.10.1; see LICENSE.txt.
import { fileURLToPath, URL } from 'node:url'
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import { devServerPlugin } from '@openc3/js-common/viteDevServerPlugin'

export default defineConfig((options) => ({
  build: {
    outDir: 'tools/scenariorunner',
    emptyOutDir: true,
    rollupOptions: {
      input: 'src/main.js',
      output: {
        format: 'systemjs',
        hashCharacters: 'hex',
        entryFileNames: '[name].js',
        chunkFileNames: '[name]-[hash:20].js',
        assetFileNames: 'assets/[name]-[hash][extname]',
      },
      external: ['single-spa', 'vue', 'vuex', 'vue-router', 'vuetify'],
      preserveEntrySignatures: 'strict',
    },
  },
  server: { port: 2931, strictPort: true },
  plugins: [vue(), devServerPlugin(options)],
  resolve: { alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) } },
  define: { __BASE_URL__: JSON.stringify('/tools/scenariorunner') },
  optimizeDeps: { entries: [] },
  test: { environment: 'jsdom', restoreMocks: true, include: ['tests/**/*.test.js'] },
}))
