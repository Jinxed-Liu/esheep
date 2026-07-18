import { FarmRole } from "./types";

export type FarmCapability =
  | "readFarm"
  | "recordProduction"
  | "editHistoricalFacts"
  | "manageCatalogs"
  | "viewAnalytics"
  | "deleteProtectedFacts"
  | "manageMembers"
  | "manageFarm"
  | "exportFarm"
  | "resolveConflicts"
  | "recoverFarm";

export const capabilitiesForRole = (role: FarmRole): FarmCapability[] => {
  switch (role) {
    case "owner":
      return ["readFarm", "recordProduction", "editHistoricalFacts", "manageCatalogs", "viewAnalytics", "deleteProtectedFacts", "manageMembers", "manageFarm", "exportFarm", "resolveConflicts", "recoverFarm"];
    case "administrator":
      return ["readFarm", "recordProduction", "editHistoricalFacts", "manageCatalogs", "viewAnalytics"];
    case "worker":
      return ["readFarm", "recordProduction"];
  }
};

const inviteAlphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ";

export function generateInviteCode(randomBytes?: Uint8Array): string {
  const bytes = randomBytes ?? crypto.getRandomValues(new Uint8Array(8));
  if (bytes.length < 8) throw new Error("邀请码随机源至少需要 8 字节。");
  return Array.from(bytes.slice(0, 8), (value) => inviteAlphabet[value % inviteAlphabet.length]).join("");
}

export function isInviteRole(value: unknown): value is Exclude<FarmRole, "owner"> {
  return value === "administrator" || value === "worker";
}
