# Build context is the repo root (see compose.yaml). Copies only the SQL
# libraries this process is allowed to reuse — not the Expo app.
FROM node:22-bookworm-slim

WORKDIR /app/home-server

COPY home-server/package.json home-server/package-lock.json ./
RUN npm ci --omit=dev

WORKDIR /app
COPY src/core ./src/core
COPY src/db ./src/db
COPY home-server/src ./home-server/src
COPY home-server/tsconfig.json ./home-server/tsconfig.json

RUN mkdir -p /data && chown node:node /data
VOLUME /data

ENV NODE_ENV=production
ENV INVENTORY_DATA_DIR=/data
ENV PORT=8788

USER node
WORKDIR /app/home-server
EXPOSE 8788

CMD ["node", "--import", "tsx", "src/index.ts"]
