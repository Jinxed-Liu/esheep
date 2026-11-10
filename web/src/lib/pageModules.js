import { lazy } from "react";

// An intent preload and React.lazy share the same in-flight import. A failed
// speculative preload can be retried when the user actually opens the page.
export function sharedModuleLoader(importModule) {
  let pending;
  return () => pending ??= importModule().catch(error => {
    pending = undefined;
    throw error;
  });
}

const entry = sharedModuleLoader(() => import("../components/pages/EntryPage.jsx"));
const events = sharedModuleLoader(() => import("../components/pages/EventsPage.jsx"));
const feeding = sharedModuleLoader(() => import("../components/pages/FeedingPage.jsx"));
const flock = sharedModuleLoader(() => import("../components/pages/FlockPage.jsx"));
const insights = sharedModuleLoader(() => import("../components/pages/InsightsPage.jsx"));
const aligned = sharedModuleLoader(() => import("../components/pages/AppAlignedPages.jsx"));
const settings = sharedModuleLoader(() => import("../components/pages/SettingsPage.jsx"));
const tmr = sharedModuleLoader(() => import("../components/pages/TMRPage.jsx"));

export const EntryPage = lazy(entry);
export const EventsPage = lazy(events);
export const FeedingPage = lazy(feeding);
export const FlockPage = lazy(flock);
export const InsightsPage = lazy(insights);
export const AlertsPage = lazy(() => aligned().then(module => ({ default: module.AlertsPage })));
export const CarePage = lazy(() => aligned().then(module => ({ default: module.CarePage })));
export const ProductionBatchesPage = lazy(() => aligned().then(module => ({ default: module.ProductionBatchesPage })));
export const SearchPage = lazy(() => aligned().then(module => ({ default: module.SearchPage })));
export const SettingsPage = lazy(settings);
export const TMRPage = lazy(tmr);

const pageLoaders = {
  entry, events, feeding, "feed-history": feeding, ingredients: feeding,
  flock, pens: flock, insights, assistant: insights,
  alerts: aligned, care: aligned, batches: aligned, search: aligned, settings,
  tmr, "tmr-feed": tmr, "tmr-produce": tmr, "tmr-batches": tmr,
  "tmr-monitor": tmr, "tmr-plans": tmr, "tmr-formulas": tmr,
};

export function preloadPage(page) {
  // Download public code only; private data still passes through the existing
  // account, membership and cloud-authority checks when navigation commits.
  return pageLoaders[page]?.().catch(() => {});
}
