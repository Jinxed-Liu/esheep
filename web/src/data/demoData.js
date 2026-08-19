const today = new Date();

function isoAt(hours, minutes) {
  const value = new Date(today);
  value.setHours(hours, minutes, 0, 0);
  return value.toISOString();
}

export const demoFarms = [
  { id: "demo-stardew", name: "星露谷牧场", role: "owner", provider: "demo" },
  { id: "demo-north", name: "北岭种羊场", role: "administrator", provider: "demo" },
];

export const demoAlerts = [
  {
    id: "weaning",
    title: "该断奶未断奶",
    count: 10,
    unit: "只",
    tone: "danger",
    target: "insights",
    description: "达到牧场设置的断奶日龄，且尚无有效断奶事件。",
  },
  {
    id: "pregnancy",
    title: "待孕检",
    count: 1,
    unit: "只",
    tone: "warning",
    target: "entry",
    description: "配种后已进入孕检窗口，尚未记录检查结果。",
  },
  {
    id: "pen",
    title: "圈舍异常",
    count: 2,
    unit: "项",
    tone: "danger",
    target: "flock",
    description: "圈舍存栏与有效转群历史需要复核。",
  },
];

export const demoEvents = [
  { id: "evt-1", at: isoAt(8, 42), type: "weight", label: "称重完成", object: "羊只 23081", actor: "张三", status: "synced" },
  { id: "evt-2", at: isoAt(8, 5), type: "feed", label: "记录投喂", object: "育肥舍 3号", actor: "李四", status: "synced" },
  { id: "evt-3", at: isoAt(7, 50), type: "health", label: "健康记录", object: "羊只 12056", actor: "王五", status: "synced" },
  { id: "evt-4", at: isoAt(7, 20), type: "transfer", label: "转群完成", object: "羊只 11023", actor: "张三", status: "synced" },
  { id: "evt-5", at: isoAt(6, 30), type: "feed", label: "记录投喂", object: "繁殖舍 1号", actor: "李四", status: "synced" },
  { id: "evt-6", at: isoAt(6, 8), type: "tmr", label: "TMR 批次完成", object: "晨料批次 0813-A", actor: "李四", status: "synced" },
  { id: "evt-7", at: isoAt(5, 55), type: "reproduction", label: "配种记录", object: "母羊 22017", actor: "王五", status: "synced" },
];

export const demoSheep = [
  { id: "s-23081", earTag: "23081", breed: "湖羊", sex: "母", stage: "空怀", pen: "繁殖舍 1号", weight: 63.8, updatedAt: isoAt(8, 42) },
  { id: "s-12056", earTag: "12056", breed: "杜泊杂交", sex: "母", stage: "妊娠", pen: "繁殖舍 1号", weight: 58.2, updatedAt: isoAt(7, 50) },
  { id: "s-11023", earTag: "11023", breed: "湖羊", sex: "公", stage: "育肥", pen: "育肥舍 3号", weight: 44.1, updatedAt: isoAt(7, 20) },
  { id: "s-22017", earTag: "22017", breed: "湖羊", sex: "母", stage: "配种", pen: "后备母羊舍", weight: 52.6, updatedAt: isoAt(5, 55) },
  { id: "s-23104", earTag: "23104", breed: "萨福克杂交", sex: "公", stage: "育肥", pen: "育肥舍 2号", weight: 47.9, updatedAt: isoAt(5, 20) },
  { id: "s-23126", earTag: "23126", breed: "湖羊", sex: "母", stage: "哺乳", pen: "产羔舍 2号", weight: 55.4, updatedAt: isoAt(4, 40) },
  { id: "s-24011", earTag: "24011", breed: "湖羊", sex: "母", stage: "哺乳羔羊", pen: "产羔舍 2号", weight: 19.8, updatedAt: isoAt(4, 12) },
  { id: "s-24018", earTag: "24018", breed: "湖羊", sex: "公", stage: "待断奶", pen: "产羔舍 1号", weight: 22.1, updatedAt: isoAt(3, 50) },
];

export const demoPens = [
  { id: "p-1", name: "繁殖舍 1号", purpose: "配种与妊娠", headCount: 18, status: "正常" },
  { id: "p-2", name: "繁殖舍 2号", purpose: "妊娠后期", headCount: 12, status: "正常" },
  { id: "p-3", name: "育肥舍 3号", purpose: "育肥", headCount: 26, status: "待复核" },
  { id: "p-4", name: "育肥舍 2号", purpose: "育肥", headCount: 22, status: "正常" },
  { id: "p-5", name: "产羔舍 1号", purpose: "产羔与哺乳", headCount: 15, status: "待复核" },
  { id: "p-6", name: "产羔舍 2号", purpose: "产羔与哺乳", headCount: 18, status: "正常" },
];

export const demoFeedRecords = [
  { id: "feed-1", at: isoAt(8, 5), pen: "育肥舍 3号", meal: "早", recipe: "育肥前期料", mode: "限量投喂", kilograms: 460, dryMatter: 405.3 },
  { id: "feed-2", at: isoAt(6, 30), pen: "繁殖舍 1号", meal: "早", recipe: "妊娠母羊料", mode: "限量投喂", kilograms: 128, dryMatter: 112.6 },
  { id: "feed-3", at: isoAt(6, 18), pen: "产羔舍 2号", meal: "全天", recipe: "泌乳母羊料", mode: "自由采食", kilograms: 96, dryMatter: 84.5 },
];

export const demoIngredients = [
  { id: "i-1", name: "玉米", category: "能量饲料", unit: "kg", dryMatter: 88, stock: 2860 },
  { id: "i-2", name: "豆粕", category: "蛋白饲料", unit: "kg", dryMatter: 89, stock: 740 },
  { id: "i-3", name: "苜蓿干草", category: "粗饲料", unit: "kg", dryMatter: 91, stock: 1240 },
  { id: "i-4", name: "青贮玉米", category: "粗饲料", unit: "kg", dryMatter: 34, stock: 8650 },
];

export const demoRecipes = [
  { id: "r-1", name: "育肥前期料", stage: "育肥前期", totalKg: 100, cp: 16.8, me: 11.2, ndf: 28.6 },
  { id: "r-2", name: "妊娠母羊料", stage: "妊娠后期", totalKg: 100, cp: 14.2, me: 10.4, ndf: 34.8 },
  { id: "r-3", name: "泌乳母羊料", stage: "哺乳期", totalKg: 100, cp: 17.4, me: 11.5, ndf: 31.2 },
];

export const demoTMRMeals = [
  { id: "tmr-am", period: "早", time: "06:00", planKg: 2000, actualKg: 1850, progress: 92, status: "completed" },
  { id: "tmr-noon", period: "中", time: "12:00", planKg: 1250, actualKg: 0, progress: 0, status: "pending" },
  { id: "tmr-pm", period: "晚", time: "18:00", planKg: 1600, actualKg: 0, progress: 0, status: "pending" },
];

export const demoInsightSeries = [42.1, 43.4, 44.2, 45.8, 47.5, 48.7, 50.2, 51.6];

export function makeDemoWorkspace() {
  return {
    mode: "demo",
    farm: demoFarms[0],
    farms: demoFarms,
    metrics: { activeSheep: 111, activePens: 18, feedsToday: 6 },
    alerts: demoAlerts,
    events: demoEvents,
    sheep: demoSheep,
    pens: demoPens,
    feedRecords: demoFeedRecords,
    ingredients: demoIngredients,
    recipes: demoRecipes,
    tmrMeals: demoTMRMeals,
    lastSyncedAt: isoAt(9, 15),
  };
}
