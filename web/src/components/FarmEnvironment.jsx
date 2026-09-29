import { useEffect, useRef, useState } from "react";
import { Cloud } from "@phosphor-icons/react/Cloud";
import { CloudRain } from "@phosphor-icons/react/CloudRain";
import { CloudSnow } from "@phosphor-icons/react/CloudSnow";
import { Drop } from "@phosphor-icons/react/Drop";
import { Moon } from "@phosphor-icons/react/Moon";
import { Sun } from "@phosphor-icons/react/Sun";
import { Wind } from "@phosphor-icons/react/Wind";
import { X } from "@phosphor-icons/react/X";
import { calculateSolarEvents } from "../lib/farmSolar.js";

export const phaseLabels = {
  dawn: "黎明", earlyMorning: "清晨", morning: "上午", noon: "正午",
  afternoon: "午后", evening: "傍晚", twilight: "暮色", night: "夜晚", unknown: "当地时间",
};
export const conditionLabels = {
  clear: "晴", cloudy: "多云", overcast: "阴", rain: "雨", sleet: "雨夹雪",
  snow: "雪", fog: "雾", wind: "有风", thunder: "雷雨", unknown: "天气暂不可用",
};

function localTime(value, timeZone, options = {}) {
  if (!value || !timeZone || !Number.isFinite(+new Date(value))) return "—";
  try { return new Intl.DateTimeFormat("zh-CN", { timeZone, hour: "2-digit", minute: "2-digit", hour12: false, ...options }).format(new Date(value)); }
  catch { return "—"; }
}

function dayLabel(value, timeZone) {
  if (!value || !timeZone) return "—";
  try { return new Intl.DateTimeFormat("zh-CN", { timeZone, month: "numeric", day: "numeric", weekday: "short" }).format(new Date(value)); }
  catch { return "—"; }
}

function iconFor(condition, night = false) {
  if (condition === "rain" || condition === "sleet" || condition === "thunder") return CloudRain;
  if (condition === "snow") return CloudSnow;
  if (condition === "wind") return Wind;
  if (condition === "cloudy" || condition === "overcast" || condition === "fog") return Cloud;
  return night ? Moon : Sun;
}

function Precipitation({ kind, intensity, mode, paused }) {
  const canvasRef = useRef(null);
  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas || !["rain", "snow", "sleet", "thunder"].includes(kind) || mode === "off") return undefined;
    const context = canvas.getContext("2d", { alpha: true });
    if (!context) return undefined;
    const media = window.matchMedia("(prefers-reduced-motion: reduce)");
    let frame = 0; let running = false; let particles = []; let last = 0;
    const snowy = kind === "snow";
    const mixed = kind === "sleet";
    const resize = () => {
      const rect = canvas.getBoundingClientRect();
      const scale = Math.min(window.devicePixelRatio || 1, 1.5);
      canvas.width = Math.max(1, Math.round(rect.width * scale));
      canvas.height = Math.max(1, Math.round(rect.height * scale));
      context.setTransform(scale, 0, 0, scale, 0, 0);
      const density = Math.min(1.6, Math.max(0.55, Number(intensity) || 0.8));
      const count = Math.min(rect.width < 650 ? 55 : 150, Math.round(rect.width * (snowy ? 0.065 : 0.09) * density));
      particles = Array.from({ length: count }, (_, index) => ({
        x: Math.random() * rect.width, y: Math.random() * rect.height,
        speed: 0.7 + Math.random() * (snowy ? 1.6 : 4),
        size: 0.8 + Math.random() * (snowy || (mixed && index % 3 === 0) ? 2.3 : 0.7),
        snow: snowy || (mixed && index % 3 === 0),
      }));
      draw(0);
    };
    const draw = (delta) => {
      const width = canvas.clientWidth; const height = canvas.clientHeight;
      context.clearRect(0, 0, width, height);
      context.lineWidth = 1.2;
      for (const particle of particles) {
        if (delta) {
          particle.x += (particle.snow ? 0.15 : -0.4) * delta;
          particle.y += particle.speed * delta;
          if (particle.y > height) { particle.y = -8; particle.x = Math.random() * width; }
          if (particle.x < -8) particle.x = width + 8;
          if (particle.x > width + 8) particle.x = -8;
        }
        if (particle.snow) {
          context.fillStyle = "rgba(255,255,255,.8)";
          context.beginPath(); context.arc(particle.x, particle.y, particle.size, 0, 2 * Math.PI); context.fill();
        } else {
          context.strokeStyle = "rgba(216,238,255,.45)";
          context.beginPath(); context.moveTo(particle.x, particle.y);
          context.lineTo(particle.x - 2, particle.y + 8 + particle.speed * 2); context.stroke();
        }
      }
    };
    const tick = (time) => {
      if (!running) return;
      if (time - last >= 33) { draw(Math.min(2, (time - last) / 33)); last = time; }
      frame = requestAnimationFrame(tick);
    };
    const update = () => {
      const animate = mode === "auto" && !media.matches && !paused && !document.hidden;
      if (animate && !running) { running = true; last = performance.now(); frame = requestAnimationFrame(tick); }
      else if (!animate && running) { running = false; cancelAnimationFrame(frame); draw(0); }
    };
    resize(); update();
    window.addEventListener("resize", resize);
    document.addEventListener("visibilitychange", update);
    media.addEventListener?.("change", update);
    return () => {
      running = false; cancelAnimationFrame(frame);
      window.removeEventListener("resize", resize);
      document.removeEventListener("visibilitychange", update);
      media.removeEventListener?.("change", update);
    };
  }, [kind, intensity, mode, paused]);
  if (!["rain", "snow", "sleet", "thunder"].includes(kind) || mode === "off") return null;
  return <canvas ref={canvasRef} className="farm-environment-precipitation" aria-hidden="true" />;
}

export function FarmEnvironmentBackground({ environment, mode, paused, surface = "home" }) {
  const scene = environment.scene;
  const condition = environment.weather?.condition ?? "unknown";
  const windCloudOpacity = condition === "wind" && Number.isFinite(environment.weather?.cloudCover)
    ? Math.min(.72, Math.max(0, environment.weather.cloudCover * .72)) : null;
  const nightBlend = scene.phase === "night" ? 1 : ["twilight", "dawn"].includes(scene.phase)
    ? Math.max(0, Math.min(1, (0.37 - scene.light) / 0.29)) : 0;
  return <div className={`farm-environment ${mode === "off" ? "is-off" : ""} ${paused ? "is-paused" : ""}`}
    data-phase={scene.phase} data-weather={condition} data-motion={mode} data-surface={surface} aria-hidden="true"
    style={{ "--farm-light": scene.light, "--farm-warmth": scene.warmth, "--night-blend": nightBlend,
      ...(windCloudOpacity == null ? {} : { "--cloud-opacity": windCloudOpacity }) }}>
    <div className="farm-environment-photo" />
    <div className="farm-environment-color" />
    <div className="farm-environment-clouds" />
    <div className="farm-environment-haze" />
    <Precipitation kind={condition} intensity={environment.weather?.precipitationIntensity} mode={mode} paused={paused} />
  </div>;
}

function Attribution({ snapshot }) {
  const attribution = snapshot?.current && snapshot?.attribution;
  if (!attribution?.logoURL) return null;
  return <a className="farm-weather-attribution" href={attribution.legalURL} target="_blank" rel="noopener noreferrer"
    aria-label={`${attribution.serviceName} 数据来源及法律归属`}>
    <img src={attribution.logoURL} alt={attribution.serviceName} />
  </a>;
}

export function FarmWeatherSummary({ environment, onOpenChange }) {
  const [open, setOpen] = useState(false);
  const triggerRef = useRef(null);
  const closeRef = useRef(null);
  const dialogRef = useRef(null);
  const { now, timeZone, solar, weather, snapshot, detail, hasLocation } = environment;
  const night = environment.scene.phase === "night";
  const Icon = iconFor(weather?.condition, night);
  const locationName = environment.location?.locationDisplayName || "当前牧场";
  const clockText = localTime(now, timeZone);
  const tomorrow = environment.localDate && environment.hasLocation
    ? calculateSolarEvents(new Date(Date.parse(`${environment.localDate}T00:00:00Z`) + 86_400_000).toISOString().slice(0, 10),
      Number(environment.location.latitude), Number(environment.location.longitude)) : null;
  const nextSun = solar?.sunsetAt && +new Date(now) < +new Date(solar.sunsetAt)
    ? `日落 ${localTime(solar.sunsetAt, timeZone)}`
    : solar?.sunriseAt && +new Date(now) < +new Date(solar.sunriseAt)
      ? `日出 ${localTime(solar.sunriseAt, timeZone)}`
      : tomorrow?.sunriseAt ? `明日日出 ${localTime(tomorrow.sunriseAt, timeZone)}` : null;
  const status = !hasLocation ? "牧场位置或时区待设置"
    : weather ? `${conditionLabels[weather.condition]} · ${weather.temperatureC == null ? "温度未提供" : `${Math.round(weather.temperatureC)}°`}`
      : snapshot?.code === "WEATHER_NOT_CONFIGURED" ? "天气服务待配置"
        : environment.error ? "天气暂不可用" : "正在读取天气";
  const stale = weather && (snapshot?.stale || Date.parse(snapshot?.expiresAt ?? "") <= +now);
  const openDetail = () => { setOpen(true); onOpenChange?.(true); };
  const closeDetail = () => { setOpen(false); onOpenChange?.(false); requestAnimationFrame(() => triggerRef.current?.focus()); };

  useEffect(() => {
    if (!open) return undefined;
    closeRef.current?.focus();
    const previous = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    if (!detail) void environment.loadDetail();
    const handleKey = (event) => {
      if (event.key === "Escape") { event.preventDefault(); closeDetail(); }
      if (event.key !== "Tab") return;
      const controls = [...dialogRef.current.querySelectorAll('button:not(:disabled),a[href],input:not(:disabled)')];
      if (!controls.length) return;
      const first = controls[0]; const last = controls.at(-1);
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
    };
    document.addEventListener("keydown", handleKey);
    return () => { document.body.style.overflow = previous; document.removeEventListener("keydown", handleKey); };
  }, [open, detail, environment.loadDetail]);

  return <>
    <div className="farm-weather-line">
      <button ref={triggerRef} className="farm-weather-summary" type="button" onClick={openDetail} aria-haspopup="dialog">
        <Icon size={23} weight="duotone" aria-hidden="true" />
        <span><strong>{status}</strong><small>{hasLocation ? `${phaseLabels[environment.scene.phase]} · 牧场当地 ${clockText}${nextSun ? ` · ${nextSun}` : ""}` : environment.localDate ? `牧场当地 ${clockText} · 请设置位置` : "查看天气与日照"}</small></span>
        <span className="farm-weather-more" aria-hidden="true">查看天气</span>
      </button>
      <Attribution snapshot={weather ? snapshot : null} />
    </div>
    {open ? <div className="farm-weather-backdrop" onPointerDown={(event) => { if (event.target === event.currentTarget) closeDetail(); }}>
      <section ref={dialogRef} className="farm-weather-detail" role="dialog" aria-modal="true" aria-labelledby="farm-weather-title">
        <header className="farm-weather-detail-header">
          <div><small>{locationName} · {timeZone || "牧场时区待确认"}</small><h2 id="farm-weather-title">牧场天气</h2></div>
          <button ref={closeRef} type="button" onClick={closeDetail} aria-label="关闭天气详情"><X size={22} /></button>
        </header>
        <div className="farm-weather-detail-body">
          <p className="farm-weather-local-time">牧场当地 {dayLabel(now, timeZone)} {clockText} · {phaseLabels[environment.scene.phase]}</p>
          <div className="farm-weather-current"><Icon size={44} weight="duotone" /><span><strong>{weather?.temperatureC == null ? "—" : `${Math.round(weather.temperatureC)}°`}</strong><small>{weather ? conditionLabels[weather.condition] : status}</small></span></div>
          {weather?.feelsLikeC != null ? <p className="farm-weather-feels">体感 {Math.round(weather.feelsLikeC)}°</p> : null}
          {stale ? <p className="farm-weather-status">天气更新暂缓 · 最近观测 {localTime(snapshot.observedAt, timeZone)}</p> : null}
          {environment.error && !weather ? <p className="farm-weather-status">{environment.error}</p> : null}
          <section className="farm-weather-detail-section"><h3>日照</h3>
            <div className="farm-weather-sun-grid"><span><Sun size={20} />日出 <b>{solar?.polar ? "今日无日出" : localTime(solar?.sunriseAt, timeZone)}</b></span><span><Moon size={20} />日落 <b>{solar?.polar ? "今日无日落" : localTime(solar?.sunsetAt, timeZone)}</b></span></div>
            <small>{solar?.source === "calculated" ? "日出日落根据牧场位置计算" : solar?.source === "provider" ? "日出日落来自天气服务" : "日出日落暂不可用"}</small>
          </section>
          {weather ? <section className="farm-weather-detail-section"><h3>当前状况</h3><div className="farm-weather-facts">
            {weather.windSpeedMps != null ? <span><Wind size={18} />风速 <b>{weather.windSpeedMps.toFixed(1)} m/s</b></span> : null}
            {weather.humidity != null ? <span><Drop size={18} />湿度 <b>{Math.round(weather.humidity * 100)}%</b></span> : null}
            {weather.visibilityM != null ? <span>能见度 <b>{(weather.visibilityM / 1000).toFixed(1)} km</b></span> : null}
          </div></section> : null}
          {detail?.availability?.hourly && detail.hourly?.length ? <section className="farm-weather-detail-section"><h3>未来 24 小时</h3><div className="farm-weather-hourly">{detail.hourly.map((hour) => <div key={hour.at}><time>{localTime(hour.at, timeZone)}</time><span>{conditionLabels[hour.condition]}</span><strong>{hour.temperatureC == null ? "—" : `${Math.round(hour.temperatureC)}°`}</strong><small>{hour.precipitationChance == null ? "" : `降水 ${Math.round(hour.precipitationChance * 100)}%`}</small></div>)}</div></section> : null}
          {detail?.availability?.daily && detail.daily?.length ? <section className="farm-weather-detail-section"><h3>未来 7 天</h3><div className="farm-weather-daily">{detail.daily.map((day) => <div key={day.at}><time>{dayLabel(day.at, timeZone)}</time><span>{conditionLabels[day.condition]}</span><strong>{day.minC == null || day.maxC == null ? "—" : `${Math.round(day.minC)}° / ${Math.round(day.maxC)}°`}</strong></div>)}</div></section> : null}
          {!detail && weather ? <p className="farm-weather-status">{environment.error || "正在读取预报…"}</p> : null}
          <p className="farm-weather-alert-note">气象预警资料尚未提供，不能据此判断当地没有预警。</p>
          {weather ? <footer className="farm-weather-source"><Attribution snapshot={snapshot} /><span>观测 {localTime(snapshot.observedAt, timeZone)} · 获取 {localTime(snapshot.fetchedAt, timeZone)}</span></footer> : null}
        </div>
      </section>
    </div> : null}
  </>;
}
