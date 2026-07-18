export interface Env {
  DB: D1Database;
  APPLE_CLIENT_ID: string;
  APPLE_TEAM_ID: string;
  APPLE_KEY_ID: string;
  APPLE_PRIVATE_KEY: string;
  APPLE_ISSUER: string;
  SESSION_SIGNING_SECRET: string;
  CREDENTIAL_ENCRYPTION_KEY: string;
  CAPABILITY_SIGNING_PRIVATE_KEY: string;
  CAPABILITY_SIGNING_KEY_ID: string;
  ACCESS_TOKEN_TTL_SECONDS: string;
  REFRESH_TOKEN_TTL_SECONDS: string;
  CAPABILITY_TTL_SECONDS: string;
  PASSWORD_PBKDF2_ITERATIONS?: string;
}

export type FarmRole = "owner" | "administrator" | "worker";

export interface AccessClaims {
  sub: string;
  sid: string;
  iat: number;
  exp: number;
  iss: "esheep-next-identity";
  aud: "esheep-next-ios";
}

export interface AuthContext {
  accountID: string;
  sessionID: string;
}

export class APIError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}
