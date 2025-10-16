# Dockerfile (at repo root)
FROM mcr.microsoft.com/playwright:v1.47.0-jammy

WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev || npm i --omit=dev
COPY server.mjs ./

ENV NODE_ENV=production
ENV PORT=10000
EXPOSE 10000

HEALTHCHECK --interval=30s --timeout=3s \
  CMD node -e "fetch('http://127.0.0.1:'+process.env.PORT+'/health').then(r=>r.ok?process.exit(0):process.exit(1)).catch(()=>process.exit(1))"

CMD ["node","server.mjs"]
