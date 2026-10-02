import { defineConfig } from "@neon/config/v1";

export default defineConfig({
  auth: true,
  dataApi: true,
  buckets: {
    "meal-images": { access: "private" },
  },
  functions: {
    mealimages: { name: "Private meal image URLs", source: "neon/functions/mealimages.ts" },
  },
});
