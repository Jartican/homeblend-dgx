import { defineConfig } from 'vite'

export default defineConfig({
  // Relative assets work both inside an .ehpk package and when the same build
  // is served from a private tailnet subpath such as /homeblend/.
  base: './',
  server: { host: true, port: 5173 },
  build: { target: 'esnext' },
})
