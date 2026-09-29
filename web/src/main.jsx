import React from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App.jsx";
import "./styles.css";
import "./skyglass.css";
import "./farmEnvironment.css";
import "./motion.css";

if (import.meta.env.PROD) {
  window.addEventListener("vite:preloadError", (event) => {
    // A Safari web app can keep an older entry bundle across a deployment.
    // Retry once with a fresh page if one of its lazy chunks is no longer here.
    try {
      const key = "esheep-preload-reload-at";
      const last = Number(sessionStorage.getItem(key) || 0);
      if (Date.now() - last < 30_000) return;
      sessionStorage.setItem(key, String(Date.now()));
      event.preventDefault();
      window.location.reload();
    } catch {
      // Leave the original error visible if session storage is unavailable.
    }
  });
}

createRoot(document.getElementById("root")).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
