import { expect, test } from "@playwright/test";

const sampleMd = "```mermaid\ngraph TD\n  A --> B\n```";

test.describe("Mermaid code block", () => {
  test("pointer/click toggles preview vs editable source", async ({ page }) => {
    await page.goto("/index.html");
    await page.waitForFunction(() => typeof (window as unknown as { __HiMD?: { setMarkdown: (s: string) => void } }).__HiMD?.setMarkdown === "function");

    await page.evaluate((md) => {
      (window as unknown as { __HiMD: { setMarkdown: (s: string) => void } }).__HiMD.setMarkdown(md);
    }, sampleMd);

    const chart = page.locator(".hm-mermaid-chart-host svg");
    await expect(chart).toBeVisible({ timeout: 30_000 });

    const toggle = page.locator(".hm-mermaid-toggle");
    await expect(toggle).toHaveAttribute("aria-label", "Edit Mermaid source");

    await toggle.click({ force: true });
    await expect(page.locator(".hm-mermaid-preview")).toBeHidden();
    await expect(toggle).toHaveAttribute("aria-label", "Show diagram");

    const pre = page.locator(".hm-codeblock-wrap.hm-mermaid-active pre");
    await expect
      .poll(async () => pre.evaluate((el) => !(el as HTMLElement).classList.contains("hm-mermaid-source-hidden")))
      .toBeTruthy();

    await toggle.click({ force: true });
    await expect(page.locator(".hm-mermaid-preview")).toBeVisible();
    await expect(toggle).toHaveAttribute("aria-label", "Edit Mermaid source");
    await expect(chart).toBeVisible();
  });
});
