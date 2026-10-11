#!/usr/bin/env bash

# Remote VPS credentials
DEPLOY_HOST="${DEPLOY_HOST:-188.245.184.80}"
DEPLOY_USER="${DEPLOY_USER:-root}"
DEPLOY_PORT="${DEPLOY_PORT:-22}"

# Leave empty to use ssh-agent/default keys.
SSH_IDENTITY_FILE="${SSH_IDENTITY_FILE:-}"

# Remote target layout
REMOTE_BASE_DIR="${REMOTE_BASE_DIR:-/opt/tprezzo}"
REMOTE_APP_DIR="$REMOTE_BASE_DIR/tprezzo"
REMOTE_DEVOPS_DIR="$REMOTE_BASE_DIR/devops"
REMOTE_COMPOSE_FILE="$REMOTE_DEVOPS_DIR/docker-compose.demo.yml"
REMOTE_APP_CONTEXT_REL="../tprezzo"
REMOTE_ENV_FILE_REL="../tprezzo/.env.demo"

# Docker Compose stack identity and host bindings.
# Use a distinct project name and ports for every frontend installation.
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-tprezzo-demo}"
APP_LOOPBACK_HOST="${APP_LOOPBACK_HOST:-127.0.0.1}"
APP_LOOPBACK_PORT="${APP_LOOPBACK_PORT:-5000}"
HTTP_PORT="${HTTP_PORT:-80}"
HTTPS_PORT="${HTTPS_PORT:-443}"
APP_IMAGE="${APP_IMAGE:-${COMPOSE_PROJECT_NAME}-app:latest}"
CERTBOT_WWW_DIR="${CERTBOT_WWW_DIR:-./demo/certbot/www}"
CERTBOT_CONF_DIR="${CERTBOT_CONF_DIR:-./demo/certbot/conf}"

# Public app domain for nginx/certbot bootstrap.
APP_DOMAIN="${APP_DOMAIN:-tprezzo.duckdns.org}"

# Required by Let's Encrypt (contact email). Keep empty and pass via script arg if preferred.
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"

# Local project layout
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCAL_APP_DIR="${LOCAL_APP_DIR:-$(dirname "$REPO_ROOT")/Tprezzo_replit}"
LOCAL_DEVOPS_DIR="$REPO_ROOT"
LOCAL_COMPOSE_FILE="$LOCAL_DEVOPS_DIR/docker-compose.demo.yml"
LOCAL_ENV_FILE="${LOCAL_ENV_FILE:-$LOCAL_APP_DIR/.env.demo}"
LOCAL_DOCKERFILE="$LOCAL_APP_DIR/Dockerfile.demo"
LOCAL_NGINX_TEMPLATE_DIR="$LOCAL_DEVOPS_DIR/demo/nginx/templates"
