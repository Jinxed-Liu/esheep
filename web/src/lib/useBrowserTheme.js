import { useLayoutEffect } from "react";

const skyColors = {
  dawn: "#455775", earlyMorning: "#c8dbe4", morning: "#bdd9e9",
  noon: "#b5d4e8", afternoon: "#bfd6e5", evening: "#77738d",
  twilight: "#343b60", night: "#102a52", unknown: "#e8f5fb",
};
const weatherColors = {
  overcast: "#8198ab", rain: "#536b85", sleet: "#536b85",
  thunder: "#304762", snow: "#adbfce", fog: "#d5e4e6",
};

// Match the visible surface, rather than the device's clock or user agent.
export function browserThemeColor({ phase, condition, mode, surface, contentTheme }) {
  if (mode === "off" || surface !== "home") {
    return contentTheme === "dark" ? "#0d1d31" : mode === "off" ? "#f6fbff" : "#e8f5fb";
  }
  if (["night", "twilight", "dawn"].includes(phase)) return skyColors[phase];
  return weatherColors[condition] ?? skyColors[phase] ?? skyColors.unknown;
}

export function useBrowserTheme(options) {
  const color = browserThemeColor(options);
  const scheme = options.contentTheme;
  useLayoutEffect(() => {
    const root = document.documentElement;
    let meta = document.querySelector('meta[name="theme-color"]');
    const created = !meta;
    if (!meta) {
      meta = document.createElement("meta");
      meta.name = "theme-color";
      document.head.append(meta);
    }
    const previousColor = meta.getAttribute("content");
    const previousCanvas = root.style.getPropertyValue("--browser-canvas");
    const previousScheme = root.style.colorScheme;
    meta.content = color;
    root.style.setProperty("--browser-canvas", color);
    root.style.colorScheme = scheme;
    return () => {
      if (created) meta.remove();
      else if (previousColor == null) meta.removeAttribute("content");
      else meta.content = previousColor;
      if (previousCanvas) root.style.setProperty("--browser-canvas", previousCanvas);
      else root.style.removeProperty("--browser-canvas");
      root.style.colorScheme = previousScheme;
    };
  }, [color, scheme]);
}
