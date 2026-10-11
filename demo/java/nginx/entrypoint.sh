#!/bin/sh
set -eu

case "${APP_DOMAIN:-}" in
  ''|*[!a-zA-Z0-9.-]*)
    echo '[java-demo] APP_DOMAIN non valido' >&2
    exit 1
    ;;
esac

template=/opt/tprezzo/nginx/site-http.conf.template
if [ -f "/etc/letsencrypt/live/$APP_DOMAIN/fullchain.pem" ] \
  && [ -f "/etc/letsencrypt/live/$APP_DOMAIN/privkey.pem" ]; then
  template=/opt/tprezzo/nginx/site-https.conf.template
fi

sed "s|__APP_DOMAIN__|$APP_DOMAIN|g" "$template" > /etc/nginx/conf.d/site.conf
nginx -t
exec nginx -g 'daemon off;'
