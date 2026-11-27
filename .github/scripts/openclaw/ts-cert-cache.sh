#!/usr/bin/env bash
# Tailscale 证书跨轮缓存的三段逻辑（2026-10-30 从 yml 步骤外置，给 yml 减重 ——
# workflow 文件 2026-10-29（f08b15f）起突破 GitHub 500KB(=512,000 字节) 上限）。
# 用法: ts-cert-cache.sh install   ←「Install cached Tailscale certs」步骤调用
#       ts-cert-cache.sh stash     ←「Trigger cert issue & stash」步骤调用
# 环境依赖：TS_CERT_GPG_KEY（stash/install 都要，GitHub Secrets 注入）；
# stash 还读 $HOME/ts.env（Enable Tailscale SSH 步骤落盘的 TS_FQDN/TS_IP）。
# 缓存内容：/var/lib/tailscale/certs 整目录（证书 + ACME 账号密钥），gpg 加密。
# 背景与设计详见 yml 中「Restore Tailscale certs」步骤注释。

set -uo pipefail
# 暂存包解密后含 ACME 账号私钥，必须先收紧 umask 再创建 /tmp 文件（否则 0644）。
umask 077
TS_CERTS_DIR=/var/lib/tailscale/certs
CERT_CACHE_DIR="$HOME/ts-cert-cache"
BLOB="$CERT_CACHE_DIR/certs.tar.gz.gpg"

install_from_cache() {
  sudo mkdir -p "$TS_CERTS_DIR"
  [ -f "$BLOB" ] || { echo "无缓存证书包，本轮将现签"; exit 0; }
  if [ -z "${TS_CERT_GPG_KEY:-}" ]; then
    echo "⚠️ TS_CERT_GPG_KEY 未配置，无法解密缓存，本轮将现签"; exit 0
  fi
  if ! gpg --batch --quiet --passphrase-fd 0 --pinentry-mode loopback -d "$BLOB" \
      > /tmp/ts-certs.tar.gz 2>/tmp/ts-gpg.err <<< "$TS_CERT_GPG_KEY"; then
    # gpg 错误里可能带命令行/环境等上下文；暂存包是公开 artifact，任何原文都不进日志。
    echo "::warning::缓存解密失败（passphrase 不匹配或包损坏？），本轮将现签；细节见 runner 本机 /tmp/ts-gpg.err"
    rm -f /tmp/ts-certs.tar.gz; exit 0
  fi
  rm -f "$BLOB"
  # 缓存包由本脚本加密生成，但仍拒绝绝对路径 / .. 成员落到 certs/ 之外。
  # 白名单只允许 "certs/" 与 "certs/<单层文件名>"；先完整列出再解包（tar 遇 .. 会拒绝，
  # 但不能依赖退出码：set -u 下未检查的失败会继续跑后续步骤）。
  if ! _entries="$(tar -tzf /tmp/ts-certs.tar.gz 2>/dev/null)"; then
    echo "::warning::缓存证书包无法读取，拒绝解包；本轮将现签"
    rm -f /tmp/ts-certs.tar.gz; exit 0
  fi
  if printf '%s\n' "$_entries" | grep -qvE '^certs/(|[^/]+)$'; then
    echo "::warning::缓存证书包含非 certs/ 成员或子目录，拒绝解包；本轮将现签"
    rm -f /tmp/ts-certs.tar.gz; exit 0
  fi
  sudo tar -C /var/lib/tailscale --no-same-owner -xzf /tmp/ts-certs.tar.gz
  rm -f /tmp/ts-certs.tar.gz
  # certs/ 下文件是 root:600：glob 与读取都必须以 root 身份做
  CRT="$(sudo sh -c 'ls /var/lib/tailscale/certs/*.crt 2>/dev/null | head -1' || true)"
  if [ -z "$CRT" ]; then
    echo "缓存包里没有证书，仅恢复 ACME 账号密钥"; exit 0
  fi
  if sudo openssl x509 -in "$CRT" -noout -checkend 86400 2>/dev/null; then
    sudo sh -c 'chmod 600 /var/lib/tailscale/certs/* 2>/dev/null || true'
    echo "✅ 已恢复有效证书（本轮零签发）："
    sudo openssl x509 -in "$CRT" -noout -subject -enddate
  else
    echo "⚠️ 缓存证书已不足 24h 有效期，丢弃 crt/key（保留 ACME 账号密钥），本轮将现签"
    sudo sh -c 'rm -f /var/lib/tailscale/certs/*.crt /var/lib/tailscale/certs/*.key'
  fi
}

stash_to_cache() {
  if [ -f "$HOME/ts.env" ]; then
    . "$HOME/ts.env"
    echo "触发 HTTPS 握手（${TS_FQDN}:8444，无缓存时现场签发，最长等 90s）..."
    if curl -sk --max-time 90 --resolve "${TS_FQDN}:8444:${TS_IP}" "https://${TS_FQDN}:8444/" -o /dev/null; then
      echo "✅ HTTPS 握手成功，证书可用"
    else
      echo "⚠️ HTTPS 握手未成功（可能仍在 LE 限频期），HTTP 端口不受影响"
    fi
  else
    echo "⚠️ ts.env 缺失（Enable Tailscale SSH 未完成？），跳过握手触发"
  fi
  CRT="$(sudo sh -c 'ls /var/lib/tailscale/certs/*.crt 2>/dev/null | head -1' || true)"
  if [ -z "$CRT" ]; then
    echo "saved=false" >> "${GITHUB_OUTPUT:?}"
    echo "⚠️ 无证书落盘（限频期内），跳过缓存回存"
    exit 0
  fi
  if [ -z "${TS_CERT_GPG_KEY:-}" ]; then
    echo "saved=false" >> "${GITHUB_OUTPUT:?}"
    echo "❌ TS_CERT_GPG_KEY 未配置，证书无法加密回存 —— 每轮都会现签，"
    echo "   很快会再撞 LE 每周 5 张限频。请尽快把 passphrase 写入仓库 Secrets。"
    exit 0
  fi
  sudo sh -c 'chmod 600 /var/lib/tailscale/certs/* 2>/dev/null || true'
  mkdir -p "$CERT_CACHE_DIR"
  sudo tar -C /var/lib/tailscale -czf /tmp/ts-certs.tar.gz certs
  # root 的 umask 未必继承调用方；先显式 600 再交给 runner 加密。
  sudo chmod 600 /tmp/ts-certs.tar.gz
  sudo chown "$(id -u):$(id -g)" /tmp/ts-certs.tar.gz
  EXP="$(sudo openssl x509 -in "$CRT" -noout -enddate | cut -d= -f2 | xargs -I{} date -d '{}' +%Y%m%d)"
  gpg --batch --quiet --yes --cipher-algo AES256 --passphrase-fd 0 --pinentry-mode loopback \
    --symmetric -o "$BLOB" /tmp/ts-certs.tar.gz <<< "$TS_CERT_GPG_KEY"
  rm -f /tmp/ts-certs.tar.gz
  {
    echo "saved=true"
    echo "key=openclaw-certs-exp-${EXP}"
  } >> "${GITHUB_OUTPUT:?}"
  echo "✅ 证书已加密暂存（到期日 ${EXP}）"
}

case "${1:-}" in
  install) install_from_cache ;;
  stash)   stash_to_cache ;;
  *) echo "用法: $0 install|stash" >&2; exit 2 ;;
esac
