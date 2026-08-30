import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  build: {
    outDir: "dist/client",
    rollupOptions: {
      output: {
        manualChunks(id) {
          if (id.includes("node_modules/@supabase") || id.includes("node_modules/@realtime") || id.includes("node_modules/iceberg-js")) return "supabase";
          if (id.includes("node_modules/@phosphor-icons") || id.includes("node_modules/@iconify") || id.includes("node_modules/@tabler")) return "icons";
          if (id.includes("node_modules/react") || id.includes("node_modules/scheduler")) return "react";
          return undefined;
        },
      },
    },
  },
  optimizeDeps: {
    // Lazy App-aligned routes use direct Phosphor subpath imports. Prebundle
    // them together so opening the first route does not trigger a dependency
    // optimizer reload halfway through a form or navigation action.
    include: [
      "react",
      "react-dom/client",
      "@phosphor-icons/react/AppleLogo",
      "@phosphor-icons/react/ArrowsLeftRight",
      "@phosphor-icons/react/Baby",
      "@phosphor-icons/react/Barn",
      "@phosphor-icons/react/BowlFood",
      "@phosphor-icons/react/CaretDown",
      "@phosphor-icons/react/CaretRight",
      "@phosphor-icons/react/ChartLineUp",
      "@phosphor-icons/react/Check",
      "@phosphor-icons/react/CheckCircle",
      "@phosphor-icons/react/ClipboardText",
      "@phosphor-icons/react/CloudArrowDown",
      "@phosphor-icons/react/CloudCheck",
      "@phosphor-icons/react/CloudSlash",
      "@phosphor-icons/react/DownloadSimple",
      "@phosphor-icons/react/Factory",
      "@phosphor-icons/react/FirstAidKit",
      "@phosphor-icons/react/ForkKnife",
      "@phosphor-icons/react/Gear",
      "@phosphor-icons/react/Globe",
      "@phosphor-icons/react/Heart",
      "@phosphor-icons/react/House",
      "@phosphor-icons/react/LockKey",
      "@phosphor-icons/react/MagnifyingGlass",
      "@phosphor-icons/react/Notebook",
      "@phosphor-icons/react/Package",
      "@phosphor-icons/react/PaperPlaneTilt",
      "@phosphor-icons/react/PencilSimpleLine",
      "@phosphor-icons/react/Plus",
      "@phosphor-icons/react/Pulse",
      "@phosphor-icons/react/Robot",
      "@phosphor-icons/react/Scales",
      "@phosphor-icons/react/ShieldCheck",
      "@phosphor-icons/react/SignIn",
      "@phosphor-icons/react/SignOut",
      "@phosphor-icons/react/Sparkle",
      "@phosphor-icons/react/SpinnerGap",
      "@phosphor-icons/react/Sun",
      "@phosphor-icons/react/Syringe",
      "@phosphor-icons/react/Tag",
      "@phosphor-icons/react/UserCircle",
      "@phosphor-icons/react/UsersThree",
      "@phosphor-icons/react/WarningCircle",
      "@phosphor-icons/react/X",
    ],
  },
  server: {
    host: "0.0.0.0",
    allowedHosts: ["terminal.local"],
    warmup: {
      clientFiles: ["./src/main.jsx"],
    },
  },
  plugins: [react()],
});
