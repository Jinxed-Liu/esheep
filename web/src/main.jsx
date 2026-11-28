import React from "react";
import { createRoot } from "react-dom/client";
import { initializeBackendSelection } from "./lib/backendSelection.js";
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

async function start() {
  await initializeBackendSelection();
  if (location.pathname === "/account/recovery") {
    const { PasswordRecovery, openRecoveryLink } = await import("./components/PasswordRecovery.jsx");
    let error = "";
    try { await openRecoveryLink(new URL(location.href)); } catch (failure) { error = failure.message; }
    createRoot(document.getElementById("root")).render(<PasswordRecovery error={error} />);
    return;
  }
  const { App } = await import("./App.jsx");
  createRoot(document.getElementById("root")).render(<React.StrictMode><App /></React.StrictMode>);
}

void start();
