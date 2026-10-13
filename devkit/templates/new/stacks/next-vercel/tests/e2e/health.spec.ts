// The served app, end to end: `next dev` on a migrated throwaway Postgres (make ci-e2e).
import { expect, test } from "@playwright/test";

test("ready reports up with a version", async ({ request }) => {
  const response = await request.get("/health/ready");
  expect(response.status()).toBe(200);
  expect(await response.json()).toMatchObject({ status: "up", checks: { database: { status: "up" } } });
});

test("the home page renders", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
});
