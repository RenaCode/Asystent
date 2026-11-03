FROM node:24-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force
COPY server.js ./
USER node
EXPOSE 8787
HEALTHCHECK CMD wget -qO- http://localhost:8787/healthz || exit 1
CMD ["node", "server.js"]
