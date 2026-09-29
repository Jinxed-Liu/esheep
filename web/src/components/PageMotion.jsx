import { useLayoutEffect, useRef } from "react";

const homeTargets = ".sky-intro > *, .sky-metric, .sky-panel-heading, .sky-production-row, .sky-action-list > button, .sky-activity-row, .sky-empty, .sky-operational-context > section";
const featureTargets = ".feature-page-top, .workspace-toolbar, .record-hub-group, .recent-records-panel, .feeding-hub-section, .analysis-filter-shell, .analysis-metric-strip, .analysis-layout > *, .workspace-panel";
const ease = "cubic-bezier(0.16, 1, 0.3, 1)";

// Animate only committed destinations. Forms keep their identity and data refreshes
// do not replay entrances. Offscreen sections reveal once as they reach the viewport.
export function PageMotion({ route, children }) {
  const host = useRef(null);
  useLayoutEffect(() => {
    const preference = window.matchMedia("(prefers-reduced-motion: reduce)");
    const page = host.current?.firstElementChild;
    if (!page || preference.matches) return;
    const home = page.classList.contains("sky-home");
    let targets = [...page.querySelectorAll(home ? homeTargets : featureTargets)];
    // Do not animate both a section and one of its descendants.
    targets = targets.filter(node => !targets.some(parent => parent !== node && parent.contains(node)));
    if (!targets.length) targets = [page];
    const animations = new Set();
    const startedAt = performance.now();
    let disposed = false;
    const reveal = (entries) => {
      if (disposed || preference.matches) return;
      let order = 0;
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        observer.unobserve(entry.target);
        const delay = performance.now() - startedAt < 150 ? Math.min(order++ * 45, 270) : 0;
        const animation = entry.target.animate([
          { opacity: 0, transform: "translateY(22px) scale(0.985)" },
          { opacity: 1, transform: "translateY(0) scale(1)" },
        ], { duration: 560, delay, easing: ease, fill: "backwards" });
        animations.add(animation);
        animation.onfinish = () => animations.delete(animation);
      }
    };
    const observer = new IntersectionObserver(reveal, { threshold: 0, rootMargin: "0px 0px -24px 0px" });
    targets.forEach(node => observer.observe(node));
    const stop = () => {
      if (!preference.matches) return;
      disposed = true;
      observer.disconnect();
      animations.forEach(animation => animation.cancel());
      animations.clear();
    };
    preference.addEventListener("change", stop);
    return () => {
      disposed = true;
      observer.disconnect();
      animations.forEach(animation => animation.cancel());
      preference.removeEventListener("change", stop);
    };
  }, [route]);

  useLayoutEffect(() => {
    const root = host.current;
    const pointer = window.matchMedia("(hover: hover) and (pointer: fine) and (prefers-reduced-motion: no-preference)");
    let frame = 0;
    let current = null;
    const reset = () => {
      cancelAnimationFrame(frame);
      if (current) {
        for (const name of ["--photo-x", "--photo-y", "--light-x", "--light-y"]) current.style.removeProperty(name);
        current = null;
      }
    };
    const move = (event) => {
      if (!pointer.matches || event.pointerType !== "mouse") return;
      const card = event.target.closest?.(".sky-production-row");
      if (card !== current) reset();
      if (!card) return;
      current = card;
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => {
        const rect = card.getBoundingClientRect();
        const x = Math.max(0, Math.min(1, (event.clientX - rect.left) / rect.width));
        const y = Math.max(0, Math.min(1, (event.clientY - rect.top) / rect.height));
        card.style.setProperty("--photo-x", `${(x - 0.5) * 14}px`);
        card.style.setProperty("--photo-y", `${(y - 0.5) * 10}px`);
        card.style.setProperty("--light-x", `${x * 100}%`);
        card.style.setProperty("--light-y", `${y * 100}%`);
      });
    };
    // Child icon transforms can change the hit target without leaving the card.
    const leave = (event) => {
      if (current && !current.contains(event.relatedTarget)) reset();
    };
    root.addEventListener("pointermove", move, { passive: true });
    root.addEventListener("pointerout", leave);
    pointer.addEventListener("change", reset);
    return () => {
      reset();
      root.removeEventListener("pointermove", move);
      root.removeEventListener("pointerout", leave);
      pointer.removeEventListener("change", reset);
    };
  }, [route]);
  return <div className="page-motion" ref={host}>{children}</div>;
}
