import path from "node:path";
import { fileURLToPath } from "node:url";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

const directory = path.dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  plugins: [
    cloudflareTest(async () => ({
      wrangler: { configPath: path.join(directory, "wrangler.jsonc") },
      miniflare: {
        d1Databases: ["DB"],
        bindings: {
          TEST_MIGRATIONS: await readD1Migrations(path.join(directory, "migrations")),
          APPLE_CLIENT_ID: "com.sheepfarm.next.dev",
          APPLE_TEAM_ID: "TESTTEAM",
          APPLE_KEY_ID: "TESTKEY",
          APPLE_PRIVATE_KEY: "test-only",
          SESSION_SIGNING_SECRET: "test-session-secret-with-sufficient-entropy",
          CREDENTIAL_ENCRYPTION_KEY: "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc=",
          CAPABILITY_SIGNING_PRIVATE_KEY: "test-only",
          CAPABILITY_SIGNING_KEY_ID: "test-key",
          PASSWORD_PBKDF2_ITERATIONS: "1000",
        },
      },
    })),
  ],
  test: {
    setupFiles: ["./test/apply-migrations.ts"],
  },
});
