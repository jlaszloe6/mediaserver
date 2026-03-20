FROM alpine:3.21
RUN apk add --no-cache dnsmasq bind-tools
EXPOSE 53/udp 53/tcp
ENTRYPOINT ["dnsmasq", "-k"]
