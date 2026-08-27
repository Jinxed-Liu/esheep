// Compatibility exports for external imports. App routes import each page
// directly so Vite can produce one chunk per feature instead of a shared
// all-features bundle.
export { default as EntryPage } from "./pages/EntryPage.jsx";
export { default as EventsPage } from "./pages/EventsPage.jsx";
export { default as FeedingPage } from "./pages/FeedingPage.jsx";
export { default as FlockPage } from "./pages/FlockPage.jsx";
export { default as InsightsPage } from "./pages/InsightsPage.jsx";
export { default as SettingsPage } from "./pages/SettingsPage.jsx";
export { default as TMRPage } from "./pages/TMRPage.jsx";
