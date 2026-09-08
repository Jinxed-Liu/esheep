FROM node:22-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates git python3 bubblewrap \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY server ./server
COPY src/lib ./src/lib
RUN mkdir /state && chown node:node /state
USER node
ENV NODE_ENV=production PORT=8080 HOST=0.0.0.0 CODEX_HARNESS_STATE_DIR=/state \
    CODEX_HARNESS_REQUIRE_SESSION_RESUME=true
EXPOSE 8080
CMD ["node", "server/container.mjs"]
