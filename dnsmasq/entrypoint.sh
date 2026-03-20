#!/bin/sh
set -e
envsubst < /etc/dnsmasq.conf.template > /etc/dnsmasq.conf
exec dnsmasq -k
