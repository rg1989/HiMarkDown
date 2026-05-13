import path from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig, devices } from "@playwright/test";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const webRoot = path.join(__dirname, "../HiMarkDown/Web");

export default defineConfig({
  testDir: "./e2e",
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  use: {
    baseURL: "http://127.0.0.1:9876",
    ...devices["Desktop Chrome"],
  },
  webServer: {
    command: `python3 -m http.server 9876 --directory "${webRoot}"`,
    url: "http://127.0.0.1:9876",
    reuseExistingServer: !process.env.CI,
  },
});
