import { describe, expect, it } from "vitest";
import { capabilitiesForRole, generateInviteCode } from "../src/policy";
import { decryptCredential, encryptCredential, signAccessToken, verifyAccessToken } from "../src/crypto";

describe("role capabilities", () => {
  it("keeps member governance owner-only", () => {
    expect(capabilitiesForRole("owner")).toContain("manageMembers");
    expect(capabilitiesForRole("owner")).toContain("resolveConflicts");
    expect(capabilitiesForRole("owner")).toContain("recoverFarm");
    expect(capabilitiesForRole("administrator")).not.toContain("manageMembers");
    expect(capabilitiesForRole("administrator")).not.toContain("recoverFarm");
    expect(capabilitiesForRole("worker")).toEqual(["readFarm", "recordProduction"]);
  });
});

describe("invite codes", () => {
  it("uses eight unambiguous uppercase characters", () => {
    const code = generateInviteCode(new Uint8Array([0, 1, 2, 3, 4, 5, 6, 7]));
    expect(code).toHaveLength(8);
    expect(code).toMatch(/^[2-9A-HJ-NP-Z]{8}$/);
    expect(code).not.toMatch(/[01IO]/);
  });
});

describe("worker security primitives", () => {
  it("accepts a valid access token and rejects a modified signature", async () => {
    const now = Math.floor(Date.now() / 1000);
    const claims = { sub: "account", sid: "session", iat: now, exp: now + 60, iss: "esheep-next-identity" as const, aud: "esheep-next-ios" as const };
    const token = await signAccessToken(claims, "test-secret-with-enough-entropy");
    await expect(verifyAccessToken(token, "test-secret-with-enough-entropy")).resolves.toMatchObject({ sub: "account", sid: "session" });
    const parts = token.split(".");
    const signature = parts[2] ?? "";
    const replacement = signature[0] === "A" ? "B" : "A";
    const modified = `${parts[0]}.${parts[1]}.${replacement}${signature.slice(1)}`;
    await expect(verifyAccessToken(modified, "test-secret-with-enough-entropy")).rejects.toMatchObject({ code: "invalid_access_token" });
  });

  it("rejects expired access tokens", async () => {
    const now = Math.floor(Date.now() / 1000);
    const token = await signAccessToken({ sub: "account", sid: "session", iat: now - 120, exp: now - 1, iss: "esheep-next-identity", aud: "esheep-next-ios" }, "test-secret");
    await expect(verifyAccessToken(token, "test-secret")).rejects.toMatchObject({ code: "expired_access_token" });
  });

  it("round-trips encrypted Apple credentials", async () => {
    const key = btoa(String.fromCharCode(...new Uint8Array(32).fill(7)));
    const encrypted = await encryptCredential("apple-refresh-token", key);
    expect(encrypted.cipherText).not.toContain("apple-refresh-token");
    await expect(decryptCredential(encrypted.cipherText, encrypted.iv, key)).resolves.toBe("apple-refresh-token");
  });
});
