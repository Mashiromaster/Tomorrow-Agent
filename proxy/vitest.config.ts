// `@cloudflare/vitest-pool-workers` is deprecated in favour of
// `@cloudflare/vitest-plugin`, which is a Vite plugin rather than a Vitest
// pool — hence `plugins: [cloudflareTest(...)]` instead of
// `test.poolOptions.workers`.
import { defineConfig } from 'vitest/config'
import { cloudflareTest } from '@cloudflare/vitest-plugin'

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: './wrangler.jsonc' },
      miniflare: {
        // Miniflare provides in-memory KV for these bindings, so tests never
        // touch a real namespace.
        kvNamespaces: ['DEVICES', 'QUOTA'],
        bindings: {
          APPLE_TEAM_ID: 'TEAMID1234',
          APP_BUNDLE_ID: 'com.example.PAgent',
          APP_ATTEST_ENV: 'development',
          UPSTREAM_BASE_URL: 'https://api.deepseek.test',
          FREE_MONTHLY_REQUESTS: '3',
          PRO_MONTHLY_REQUESTS: '10',
          DEEPSEEK_API_KEY: 'sk-ant-test-key',
          JWT_SIGNING_KEY: 'test-signing-key-not-a-real-secret',
        },
      },
    }),
  ],
})
