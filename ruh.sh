#!/usr/bin/env bash
# Instala o cloudflared, garante o SSH ligado e conecta esta máquina ao túnel
# ssh-amadigital (ssh.amadigital.org.br -> localhost:22).
#
# Uso:  sudo ./cloudflared-ssh.sh
set -euo pipefail

# Cole aqui o token do túnel (só a parte eyJ..., sem "sudo cloudflared service install").
TOKEN="eyJhIjoiYjE3NjgwZjhmNTU3OTE3YTZjZTJjZWJmMjlhZjE1YTEiLCJ0IjoiNDBlOTBiNTctZmY0YS00NzQ0LTg4NWYtYzNhMTU2NDExMzE4IiwicyI6IlltUmtNR1ZsWkRFdFpqVXdOUzAwTm1ZeUxXSTNaRE10T1RKbVptVXpObVF6TXpFMCJ9"

# Opcional: chave pública SSH para liberar acesso (ex.: "ssh-ed25519 AAAA... deploy").
PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINZF6JXlqYHSgKbigNtKtA6Y3nCs48Sz1Ii8VcTRAOJ/ pedro3g@ama"

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERRO: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "rode como root: sudo $0"
case "$TOKEN" in eyJ*) ;; *) die "o TOKEN no topo do script não foi preenchido" ;; esac

download() {
  if command -v curl >/dev/null 2>&1; then curl -fsSL -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then wget -qO "$2" "$1"
  else die "precisa de curl ou wget"; fi
}

pkg_install() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  elif command -v dnf >/dev/null 2>&1; then dnf install -y "$@"
  elif command -v yum >/dev/null 2>&1; then yum install -y "$@"
  elif command -v apk >/dev/null 2>&1; then apk add "$@"
  else die "gerenciador de pacotes não reconhecido; instale $* manualmente"; fi
}

has_systemd() { command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; }

# 1. cloudflared: binário oficial do GitHub, para a arquitetura desta máquina
case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  armv7l|armv6l) ARCH=arm ;;
  i386|i686)     ARCH=386 ;;
  *) die "arquitetura não suportada: $(uname -m)" ;;
esac

log "Instalando cloudflared (linux-$ARCH)"
download "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH" /usr/local/bin/cloudflared
chmod +x /usr/local/bin/cloudflared
/usr/local/bin/cloudflared --version

# 2. Servidor SSH: o túnel entrega o tráfego em localhost:22, então o sshd precisa estar de pé
log "Verificando o servidor SSH"
if ! command -v sshd >/dev/null 2>&1 && [ ! -x /usr/sbin/sshd ]; then
  if command -v apk >/dev/null 2>&1; then pkg_install openssh; else pkg_install openssh-server; fi
fi
if has_systemd; then
  systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd
fi
if command -v ss >/dev/null 2>&1 && ! ss -ltn | grep -qE '[:.]22[[:space:]]'; then
  echo "AVISO: nada escutando na porta 22. O túnel aponta para localhost:22."
fi

# 3. Chave pública (opcional) no usuário que rodou o sudo
if [ -n "$PUBKEY" ]; then
  U="${SUDO_USER:-root}"
  G="$(id -gn "$U")"
  H="$(getent passwd "$U" | cut -d: -f6)"
  log "Liberando a chave pública para o usuário $U"
  install -d -m 700 -o "$U" -g "$G" "$H/.ssh"
  touch "$H/.ssh/authorized_keys"
  grep -qxF "$PUBKEY" "$H/.ssh/authorized_keys" || printf '%s\n' "$PUBKEY" >> "$H/.ssh/authorized_keys"
  chown "$U:$G" "$H/.ssh/authorized_keys"
  chmod 600 "$H/.ssh/authorized_keys"
fi

# 4. Conecta ao túnel e deixa rodando como serviço
log "Conectando ao túnel"
if has_systemd; then
  # Rodar de novo reinstala do zero, sem o erro "service is already installed"
  if [ -f /etc/systemd/system/cloudflared.service ]; then
    /usr/local/bin/cloudflared service uninstall || true
  fi
  /usr/local/bin/cloudflared service install "$TOKEN"
  tunnel_logs() { journalctl -u cloudflared --no-pager -n 200 2>/dev/null; }
else
  # Sem systemd (container, WSL antigo): roda em segundo plano
  pkill -f 'cloudflared tunnel' 2>/dev/null || true
  nohup /usr/local/bin/cloudflared tunnel --no-autoupdate run --token "$TOKEN" >/var/log/cloudflared.log 2>&1 &
  tunnel_logs() { cat /var/log/cloudflared.log 2>/dev/null; }
fi

log "Aguardando a conexão com a Cloudflare"
for _ in $(seq 1 30); do
  if tunnel_logs | grep -q "Registered tunnel connection"; then
    log "Pronto: túnel conectado. O status no painel da Cloudflare deve estar Healthy."
    exit 0
  fi
  sleep 1
done

tunnel_logs | tail -n 30
die "o túnel não conectou em 30s; mande as linhas acima"
