import { resolve } from 'path'
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import { devServerPlugin } from '@openc3/js-common/viteDevServerPlugin'

const DEFAULT_EXTENSIONS = ['.mjs', '.js', '.ts', '.jsx', '.tsx', '.json']

export default defineConfig((options) => {
  return {
    build: {
      outDir: 'tools/mailbox',
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
    server: {
      port: 2930,
    },
    plugins: [
      vue(),
      devServerPlugin(options),
    ],
    resolve: {
      alias: {
        '@': resolve(__dirname, './src'),
      },
      extensions: [...DEFAULT_EXTENSIONS, '.vue'],
    },
    define: {
      __BASE_URL__: JSON.stringify('/tools/mailbox'),
    },
    optimizeDeps: {
      entries: [],
    },
  }
})
