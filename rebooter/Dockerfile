FROM node:20-alpine
RUN apk add --no-cache curl bash iputils tzdata jq
WORKDIR /app
COPY server/package.json server/package-lock.json* server/ /app/server/
RUN cd /app/server && npm install --omit=dev
COPY scripts/ /app/scripts/
COPY server/views/ /app/server/views/
RUN chmod +x /app/scripts/repeater_reboot.sh
ENV PORT=3333 TZ=Europe/Paris
EXPOSE 3333
CMD ["node", "/app/server/server.js"]
