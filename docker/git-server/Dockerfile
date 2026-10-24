FROM alpine:latest

RUN apk add --no-cache git git-daemon

EXPOSE 9418

CMD ["git", "daemon", "--base-path=/git", "--export-all", "--enable=receive-pack", "--reuseaddr", "--informative-errors", "--verbose"]
