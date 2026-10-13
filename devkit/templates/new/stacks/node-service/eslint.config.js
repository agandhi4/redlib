import js from "@eslint/js";
import tseslint from "typescript-eslint";

export default tseslint.config(
  { ignores: ["dist/", "devkit/"] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
);
