import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// base './' — Capacitor served aus dem App-Bundle, absolute Pfade brechen dort.
export default defineConfig({
  base: "./",
  plugins: [react()],
});
