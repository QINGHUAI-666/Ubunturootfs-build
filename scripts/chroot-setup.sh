#!/usr/bin/env bash
# =============================================================================
#  在 chroot 内部运行：把 debootstrap 基础系统配置成完整的 Ubuntu 26.04 arm64 rootfs
#    - 构建期用 EC2 us-east-2 快速源，配置完成后切换为中科大(USTC)完整软件源
#    - 中文本地化（zh_CN.UTF-8）
#    - 常用工具
#    - root / ubuntu 用户、sudo 免密、OpenSSH 密码登录
#    - systemd（默认 multi-user、启用 ssh 服务）
#    - zsh + powerlevel10k（仅左侧、Nerd Font 图标）+ 插件
#    - 美观的启动欢迎语
#    - NVM + 最新 LTS Node.js
#    - 最新版 dsh (DeepSeek Harness)
# =============================================================================
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true
export HOME=/root
export LANG=C.UTF-8
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RELEASE="resolute"
# 构建期镜像：EC2 us-east-2（与 GitHub runner 同区域，下载快）
BUILD_MIRROR="http://us-east-2.ec2.archive.ubuntu.com/ubuntu"
# 最终镜像：中科大（rootfs 交付后国内使用）
FINAL_MIRROR="https://mirrors.ustc.edu.cn/ubuntu-ports"

log() { printf '\033[1;36m[setup]\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 双保险：确保 /proc /sys 已挂载（debootstrap second-stage 可能卸载过 /proc，
# 导致 systemd postinst 报 “/proc is not mounted / Cannot open /etc/machine-id”）
# ---------------------------------------------------------------------------
for _m in proc sys; do
  if ! mountpoint -q "/$_m" 2>/dev/null; then
    mount -t "$_m" "$_m" "/$_m" 2>/dev/null || mount -o bind "/$_m" "/$_m" 2>/dev/null || true
  fi
done

# ---------------------------------------------------------------------------
# 阻止安装包时自动启动服务（chroot 内没有运行中的 systemd）
# ---------------------------------------------------------------------------
cat > /usr/sbin/policy-rc.d <<'POLICY'
#!/bin/sh
exit 101
POLICY
chmod 0755 /usr/sbin/policy-rc.d

# ===========================================================================
# 1. 构建期软件源：EC2 us-east-2（DEB822 格式，完整组件）
# ===========================================================================
log "配置构建期软件源(EC2 us-east-2)"
cat > /etc/apt/sources.list.d/ubuntu.sources <<SRC
# Ubuntu 26.04 (Resolute Raccoon) arm64 —— 构建期 EC2 完整软件源
# 含 main / universe / restricted / multiverse 以及 updates / backports / security
Types: deb
URIs: ${BUILD_MIRROR}
Suites: ${RELEASE} ${RELEASE}-updates ${RELEASE}-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: ${BUILD_MIRROR}
Suites: ${RELEASE}-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

# 如需源码仓库，取消下面注释即可
# Types: deb-src
# URIs: ${BUILD_MIRROR}
# Suites: ${RELEASE} ${RELEASE}-updates ${RELEASE}-backports
# Components: main restricted universe multiverse
# Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
SRC

# 统一使用 DEB822，清理传统 sources.list
rm -f /etc/apt/sources.list
rm -f /etc/apt/sources.list.d/*.list

log "apt-get update"
apt-get update

# 升级到 26.04.1（resolute-updates / resolute-security 中的点版本包）
log "升级到 26.04.1 点版本"
apt-get -y dist-upgrade

# ===========================================================================
# 2. 基础系统组件
# ===========================================================================
log "安装基础系统组件"
apt-get install -y \
  systemd systemd-sysv dbus \
  locales tzdata \
  ca-certificates apt-utils \
  sudo openssh-server openssh-client \
  zsh bash bash-completion \
  git curl wget \
  gnupg \
  man-db manpages less file

# ===========================================================================
# 3. 中文本地化
# ===========================================================================
log "配置中文本地化环境"
apt-get install -y language-pack-zh-hans language-pack-zh-hans-base manpages-zh

sed -i 's/^# *\(zh_CN.UTF-8 UTF-8\)/\1/' /etc/locale.gen || true
sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen || true
grep -q '^zh_CN.UTF-8 UTF-8' /etc/locale.gen || echo 'zh_CN.UTF-8 UTF-8' >> /etc/locale.gen
grep -q '^en_US.UTF-8 UTF-8' /etc/locale.gen || echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
locale-gen zh_CN.UTF-8 en_US.UTF-8
update-locale LANG=zh_CN.UTF-8 LANGUAGE=zh_CN:zh:en_US:en LC_CTYPE=zh_CN.UTF-8

# 时区：上海
echo "tzdata tzdata/Areas select Asia" | debconf-set-selections
echo "tzdata tzdata/Zones select Shanghai" | debconf-set-selections
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
dpkg-reconfigure -f noninteractive tzdata 2>/dev/null || true

# ===========================================================================
# 4. 常用工具
# ===========================================================================
log "安装常用工具"
apt-get install -y \
  build-essential pkg-config \
  python3 python3-pip python3-venv python3-dev \
  vim nano \
  htop btop \
  tmux screen \
  rsync \
  unzip zip tar xz-utils bzip2 \
  tree jq \
  ripgrep fd-find fzf zoxide bat eza \
  lsof strace \
  net-tools iproute2 iputils-ping dnsutils \
  procps ncdu duf aria2

# Debian 命名兼容：bat->batcat，fd->fdfind
ln -sf /usr/bin/batcat /usr/local/bin/bat 2>/dev/null || true
ln -sf /usr/bin/fdfind /usr/local/bin/fd 2>/dev/null || true

# ===========================================================================
# 5. 用户与密码
# ===========================================================================
log "创建用户并设置密码"
echo "root:123456" | chpasswd

# 确保附加组存在（debootstrap 最小系统可能缺少 netdev 等组）
for _g in sudo adm dialout cdrom floppy audio dip video plugdev netdev; do
  getent group "$_g" >/dev/null 2>&1 || groupadd "$_g" || true
done

id -u ubuntu >/dev/null 2>&1 || useradd -m -s /bin/zsh \
  -G sudo,adm,dialout,cdrom,floppy,audio,dip,video,plugdev,netdev ubuntu
echo "ubuntu:123456" | chpasswd

# sudo 免密（ubuntu）
cat > /etc/sudoers.d/ubuntu <<'SUDOERS'
ubuntu ALL=(ALL:ALL) NOPASSWD:ALL
SUDOERS
chmod 0440 /etc/sudoers.d/ubuntu
grep -q '^root\s' /etc/sudoers 2>/dev/null || echo 'root ALL=(ALL:ALL) ALL' >> /etc/sudoers

# 默认 shell 统一为 zsh
usermod -s /bin/zsh root
usermod -s /bin/zsh ubuntu

# ===========================================================================
# 6. 主机名
# ===========================================================================
log "设置主机名"
echo "droidspaces" > /etc/hostname
cat > /etc/hosts <<'HOSTS'
127.0.0.1   localhost
127.0.1.1   droidspaces

::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
HOSTS

# ===========================================================================
# 7. OpenSSH（密码登录 + root 登录）
# ===========================================================================
log "配置 OpenSSH"
mkdir -p /run/sshd
ssh-keygen -A

cat > /etc/ssh/sshd_config.d/99-droidspaces.conf <<'SSHD'
# DroidSpaces rootfs 专用配置
Port 22
AddressFamily inet
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
SSHD

# ===========================================================================
# 8. systemd
# ===========================================================================
log "配置 systemd"
ln -sf /lib/systemd/system/multi-user.target /etc/systemd/system/default.target

# chroot 内 systemctl 无法连接 systemd，手动建立 wants 符号链接来“启用”服务
enable_svc() {
  local unit="$1" src=""
  for p in /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system; do
    [ -f "$p/$unit" ] && { src="$p/$unit"; break; }
  done
  [ -z "$src" ] && { echo "!! 未找到单元 $unit"; return 1; }
  mkdir -p /etc/systemd/system/multi-user.target.wants
  ln -sf "$src" "/etc/systemd/system/multi-user.target.wants/$unit"
  echo "启用 $unit"
}
enable_svc ssh.service

# ===========================================================================
# 9. 启动欢迎语（美观 + 实用：展示系统/网络/资源/环境信息）
# ===========================================================================
log "安装启动欢迎语"
cat > /usr/local/bin/welcome <<'WELCOME'
#!/usr/bin/env bash
# welcome —— DroidSpaces 启动欢迎语（由交互式 shell 调用）
set +e

R=$'\033[0m'; B=$'\033[1m'; DIM=$'\033[2m'
RED=$'\033[38;5;203m'; GRN=$'\033[38;5;114m'; YEL=$'\033[38;5;221m'
BLU=$'\033[38;5;75m';  MAG=$'\033[38;5;176m'; CYN=$'\033[38;5;80m'
GRY=$'\033[38;5;245m'; WHT=$'\033[38;5;255m'

[ -r /etc/os-release ] && . /etc/os-release
: "${PRETTY_NAME:=Ubuntu Linux}"
HOST="$(hostname 2>/dev/null || echo localhost)"
U="$(id -un 2>/dev/null || echo "${USER:-unknown}")"

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -z "$IP" ] && IP="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
[ -z "$IP" ] && IP="未分配"

KERNEL="$(uname -r 2>/dev/null || echo '-')"
ARCH="$(uname -m 2>/dev/null || echo '-')"
UP="$(uptime -p 2>/dev/null | sed 's/^up *//')"; [ -z "$UP" ] && UP="刚刚启动"
LOAD="$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"; [ -z "$LOAD" ] && LOAD="-"
MEM="$(free -h 2>/dev/null | awk '/^Mem:/{print $3" / "$2}')"; [ -z "$MEM" ] && MEM="-"
DISK="$(df -h / 2>/dev/null | awk 'NR==2{printf "%s / %s (%s)", $3, $2, $5}')"; [ -z "$DISK" ] && DISK="-"
NPROC="$(nproc 2>/dev/null)"; [ -z "$NPROC" ] && NPROC="-"

NODE_V="$(node -v 2>/dev/null || echo '未安装')"
DSH_V="已就绪"; command -v dsh >/dev/null 2>&1 || DSH_V="未安装"

printf '\n'
printf '%s\n' "  ${B}${CYN}╭─ ${WHT}${B}${PRETTY_NAME}${R}${DIM}${CYN} · DroidSpaces${R}"
printf '%s\n' "  ${DIM}${CYN}│${R}"
printf '%s\n' "  ${DIM}${CYN}│${R}  ${B}${GRN}●${R} ${GRY}主机${R}     : ${WHT}${HOST}${R}   ${GRY}用户${R} : ${WHT}${U}${R}"
printf '%s\n' "  ${DIM}${CYN}│${R}  ${B}${BLU}●${R} ${GRY}内核${R}     : ${WHT}${KERNEL}${R} (${ARCH})"
printf '%s\n' "  ${DIM}${CYN}│${R}  ${B}${MAG}●${R} ${GRY}IP 地址${R}  : ${WHT}${IP}${R}"
printf '%s\n' "  ${DIM}${CYN}│${R}  ${B}${YEL}●${R} ${GRY}运行时间${R}  : ${WHT}${UP}${R}"
printf '%s\n' "  ${DIM}${CYN}│${R}  ${B}${CYN}●${R} ${GRY}负载/核心${R} : ${WHT}${LOAD}${R} / ${WHT}${NPROC}${R}"
printf '%s\n' "  ${DIM}${CYN}│${R}  ${B}${GRN}●${R} ${GRY}内存${R}     : ${WHT}${MEM}${R}"
printf '%s\n' "  ${DIM}${CYN}│${R}  ${B}${BLU}●${R} ${GRY}磁盘 /${R}   : ${WHT}${DISK}${R}"
printf '%s\n' "  ${DIM}${CYN}│${R}"
printf '%s\n' "  ${DIM}${CYN}│${R}  ${B}${MAG}●${R} ${GRY}环境${R}     : Node ${WHT}${NODE_V}${R} · dsh ${WHT}${DSH_V}${R}"
printf '%s\n' "  ${DIM}${CYN}│${R}"
printf '%s\n' "  ${DIM}${CYN}╰─ ${GRY}常用别名 ll / la / lt · 欢迎使用${R}"
printf '\n'
WELCOME
chmod 0755 /usr/local/bin/welcome

# 禁用系统 MOTD，避免与欢迎语重复显示
rm -f /etc/motd
: > /etc/motd
rm -f /etc/update-motd.d/* 2>/dev/null || true

# ===========================================================================
# 10. zsh 主题（powerlevel10k，仅左侧 + Nerd Font 图标）与插件
# ===========================================================================
log "安装 zsh 主题与插件"
mkdir -p /usr/share/zsh
git clone --depth 1 https://github.com/romkatv/powerlevel10k.git      /usr/share/zsh/powerlevel10k
git clone --depth 1 https://github.com/zsh-users/zsh-autosuggestions.git /usr/share/zsh/zsh-autosuggestions
git clone --depth 1 https://github.com/zsh-users/zsh-syntax-highlighting.git /usr/share/zsh/zsh-syntax-highlighting
git clone --depth 1 https://github.com/zsh-users/zsh-completions.git     /usr/share/zsh/zsh-completions

# p10k 配置：全部左侧、powerline 分隔、文件夹/Git/系统图标
cat > /etc/zsh/p10k.zsh <<'P10K'
'builtin' 'local' '-a' 'p10k_config_opts'
[[ ! -o 'aliases'         ]] || p10k_config_opts+=('aliases')
[[ ! -o 'sh_glob'         ]] || p10k_config_opts+=('sh_glob')
[[ ! -o 'no_brace_expand' ]] || p10k_config_opts+=('no_brace_expand')
'builtin' 'setopt' 'no_aliases' 'no_sh_glob' 'brace_expand'

() {
  emulate -L zsh -o extended_glob

  unset -m '(POWERLEVEL9K_*|DEFAULT_USER)~POWERLEVEL9K_GITSTATUS_DIR'
  autoload -Uz is-at-least && is-at-least 5.1 || return

  # 字体与图标模式
  typeset -g POWERLEVEL9K_MODE=nerdfont-complete
  typeset -g POWERLEVEL9K_ICON_PADDING=none
  typeset -g POWERLEVEL9K_ICON_BEFORE_CONTENT=true

  # 布局：全部在左侧，右侧为空
  typeset -g POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(os_icon dir vcs prompt_char)
  typeset -g POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=()
  typeset -g POWERLEVEL9K_PROMPT_ON_NEWLINE=false
  typeset -g POWERLEVEL9K_PROMPT_ADD_NEWLINE=true

  # 分隔符（powerline 风格，用 $'...' 直接内嵌 Unicode 字符，避免 \u 不被解析）
  typeset -g POWERLEVEL9K_LEFT_SEGMENT_SEPARATOR=$'\uE0B0'
  typeset -g POWERLEVEL9K_LEFT_SUBSEGMENT_SEPARATOR=$'\uE0B1'
  typeset -g POWERLEVEL9K_LEFT_SEGMENT_END_SEPARATOR=' '

  # os_icon：系统图标（Linux）
  typeset -g POWERLEVEL9K_OS_ICON_FOREGROUND=255
  typeset -g POWERLEVEL9K_OS_ICON_BACKGROUND=25
  typeset -g POWERLEVEL9K_OS_ICON_CONTENT_EXPANSION='${P9K_CONTENT}'

  # dir：文件夹图标 + 路径
  typeset -g POWERLEVEL9K_DIR_FOREGROUND=254
  typeset -g POWERLEVEL9K_DIR_BACKGROUND=31
  typeset -g POWERLEVEL9K_DIR_PREFIX=$'\uF07B '
  typeset -g POWERLEVEL9K_DIR_ANCHOR_FOREGROUND=254
  typeset -g POWERLEVEL9K_DIR_ANCHOR_BOLD=true
  typeset -g POWERLEVEL9K_SHORTEN_STRATEGY=truncate_to_unique
  typeset -g POWERLEVEL9K_SHORTEN_DELIMITER=''
  typeset -g POWERLEVEL9K_DIR_MAX_LENGTH=40
  typeset -g POWERLEVEL9K_DIR_TRUNCATE_BEFORE_MARKER=false

  # vcs：Git 图标 + 分支 + 状态
  typeset -g POWERLEVEL9K_VCS_FOREGROUND=0
  typeset -g POWERLEVEL9K_VCS_BACKGROUND=149
  typeset -g POWERLEVEL9K_VCS_CLEAN_FOREGROUND=0
  typeset -g POWERLEVEL9K_VCS_CLEAN_BACKGROUND=149
  typeset -g POWERLEVEL9K_VCS_MODIFIED_FOREGROUND=0
  typeset -g POWERLEVEL9K_VCS_MODIFIED_BACKGROUND=178
  typeset -g POWERLEVEL9K_VCS_UNTRACKED_FOREGROUND=0
  typeset -g POWERLEVEL9K_VCS_UNTRACKED_BACKGROUND=209
  typeset -g POWERLEVEL9K_VCS_BRANCH_ICON=$'\uF126 '
  typeset -g POWERLEVEL9K_VCS_UNTRACKED_ICON='?'
  typeset -g POWERLEVEL9K_VCS_STAGED_ICON='+'
  typeset -g POWERLEVEL9K_VCS_UNSTAGED_ICON='!'

  # prompt_char：❯
  typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_{VIINS,VICMD,VIVIS}_FOREGROUND=76
  typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_{VIINS,VICMD,VIVIS}_FOREGROUND=196
  typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_VIINS_CONTENT_EXPANSION='❯'
  typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_VIINS_CONTENT_EXPANSION='❯'
}

(( ${#p10k_config_opts} )) && setopt ${p10k_config_opts[@]}
'builtin' 'unset' 'p10k_config_opts'
P10K

# 系统级 zshrc
cat > /etc/zsh/zshrc <<'ZSHRC'
# /etc/zsh/zshrc —— 系统级 zsh 配置（Ubuntu 26.04 · DroidSpaces）

# ---------- 基础 ----------
export LANG=zh_CN.UTF-8
export LC_ALL=zh_CN.UTF-8
umask 022

# ---------- 历史记录 ----------
HISTFILE="$HOME/.zsh_history"
HISTSIZE=50000
SAVEHIST=50000
setopt EXTENDED_HISTORY HIST_IGNORE_ALL_DUPS HIST_IGNORE_SPACE SHARE_HISTORY HIST_VERIFY INC_APPEND_HISTORY

# ---------- 目录/跳转 ----------
setopt AUTO_CD AUTO_PUSHD PUSHD_IGNORE_DUPS GLOB_DOTS

# ---------- 补全增强 ----------
setopt COMPLETE_IN_WORD AUTO_MENU ALWAYS_TO_END
unsetopt BEEP FLOW_CONTROL

# ---------- 补全 ----------
# 初始化 dircolors，为补全列表提供颜色（目录/文件用不同颜色显示）
command -v dircolors >/dev/null 2>&1 && eval "$(dircolors -b)"
[ -d /usr/share/zsh/zsh-completions/src ] && fpath=(/usr/share/zsh/zsh-completions/src $fpath)
autoload -Uz compinit
compinit -d "$HOME/.zcompdump"
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}' 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*' 'l:|=* r:|=*'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' rehash true
zstyle ':completion:*' group-name ''
zstyle ':completion:*:descriptions' format '%F{cyan}-- %d --%f'
zstyle ':completion:*:messages' format '%F{magenta}-- %d --%f'
zstyle ':completion:*:warnings' format '%F{red}-- 没有匹配项 --%f'

# ---------- 插件 ----------
# 自动建议：history + completion 双策略 → 命令补全 + 文件路径补全都有灰色提示
source /usr/share/zsh/zsh-autosuggestions/zsh-autosuggestions.zsh 2>/dev/null
ZSH_AUTOSUGGEST_STRATEGY=(history completion)
ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=20
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=#8a919c"
source /usr/share/zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh 2>/dev/null

# ---------- 主题（powerlevel10k，仅左侧） ----------
# 关闭即时提示：在 DroidSpaces/headless 无缓存环境下更稳妥
typeset -g POWERLEVEL9K_INSTANT_PROMPT=off
source /usr/share/zsh/powerlevel10k/powerlevel10k.zsh-theme 2>/dev/null
[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh

# ---------- NVM ----------
export NVM_DIR="/usr/local/nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion" 2>/dev/null

# ---------- 现代 CLI 工具 ----------
command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init zsh)"
command -v fzf >/dev/null 2>&1 && source /usr/share/doc/fzf/examples/key-bindings.zsh 2>/dev/null
command -v fzf >/dev/null 2>&1 && source /usr/share/doc/fzf/examples/completion.zsh 2>/dev/null

# ---------- 别名（ls 带图标等） ----------
alias ls='eza --icons --group-directories-first --color=auto'
alias ll='eza -l --icons --group-directories-first --git --color=auto'
alias la='eza -la --icons --group-directories-first --git --color=auto'
alias lt='eza --tree --level=2 --icons --color=auto'
alias l='eza -1 --icons --color=auto'
alias cat='batcat --paging=never --style=plain'
alias grep='rg --color=auto'
alias rg='rg --color=auto'
alias top='btop'
alias du='duf'
alias df='duf'
alias vi='vim'

# ---------- 实用别名 ----------
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias mkdir='mkdir -pv'
alias cp='cp -iv'
alias mv='mv -iv'
alias rm='rm -iv'
alias ports='ss -tulpn'
alias myip='hostname -I'
alias cls='clear'
alias path='echo $PATH | tr ":" "\n"'
alias untar='tar -xvf'

# ---------- 欢迎语（仅交互式） ----------
if [[ -o interactive ]]; then
  command -v welcome >/dev/null 2>&1 && welcome
fi
ZSHRC

# 用户级 .zshrc / .p10k.zsh
for h in /root /home/ubuntu; do
  [ -d "$h" ] || continue
  cat > "$h/.zshrc" <<'EOF'
# 用户自定义覆盖（其余配置见 /etc/zsh/zshrc）
EOF
  cat > "$h/.p10k.zsh" <<'EOF'
# 指向系统级 p10k 配置
source /etc/zsh/p10k.zsh
EOF
  touch "$h/.zsh_history"
done
chown -R ubuntu:ubuntu /home/ubuntu

# bash 兜底配置
cat >> /etc/bash.bashrc <<'BASHRC'

# ---------- DroidSpaces 追加配置 ----------
export NVM_DIR="/usr/local/nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

command -v eza >/dev/null 2>&1 && {
  alias ls='eza --icons --group-directories-first --color=auto'
  alias ll='eza -l --icons --group-directories-first --git --color=auto'
  alias la='eza -la --icons --group-directories-first --git --color=auto'
}
command -v batcat >/dev/null 2>&1 && alias cat='batcat --paging=never --style=plain'

case $- in
  *i*) command -v welcome >/dev/null 2>&1 && welcome ;;
esac
BASHRC

# ===========================================================================
# 11. NVM + 最新 LTS Node.js
# ===========================================================================
log "安装 NVM 并安装最新 LTS Node.js"
export NVM_DIR="/usr/local/nvm"
mkdir -p "$NVM_DIR"
git clone --depth 1 https://github.com/nvm-sh/nvm.git "$NVM_DIR"
. "$NVM_DIR/nvm.sh"

nvm install --lts
nvm alias default 'lts/*'
nvm use --lts

# dsh 要求 Node >= 24.9，校验一下
NV=$(node -v | sed 's/^v//')
MAJOR=$(echo "$NV" | cut -d. -f1)
MINOR=$(echo "$NV" | cut -d. -f2)
if [ "$MAJOR" -lt 24 ] || { [ "$MAJOR" -eq 24 ] && [ "$MINOR" -lt 9 ]; }; then
  log "Node ${NV} 不满足 dsh 要求(>=24.9)，改装最新版 Node"
  nvm install node
  nvm alias default node
fi

# 让 node/npm/npx/dsh 全局可见（供 systemd、脚本使用）
NVM_BIN="$(dirname "$(nvm which current)")"

# ===========================================================================
# 12. 最新版 dsh（DeepSeek Harness）
# ===========================================================================
log "安装最新版 dsh (DeepSeek Harness)"
NODE_OPTIONS="--max-old-space-size=4096" npm install -g @deepseek-ai/dsh --no-audit --no-fund

ln -sf "$NVM_BIN/node"     /usr/local/bin/node
ln -sf "$NVM_BIN/npm"      /usr/local/bin/npm
ln -sf "$NVM_BIN/npx"      /usr/local/bin/npx
[ -e "$NVM_BIN/corepack" ] && ln -sf "$NVM_BIN/corepack" /usr/local/bin/corepack
[ -e "$NVM_BIN/dsh" ]      && ln -sf "$NVM_BIN/dsh" /usr/local/bin/dsh

log "Node: $(node -v)   npm: $(npm -v)"
dsh --version 2>/dev/null || log "dsh 已安装（版本输出见启动日志）"

# ===========================================================================
# 13. NVM 环境（供 login shell / bash）
# ===========================================================================
cat > /etc/profile.d/nvm.sh <<'NVMPROFILE'
export NVM_DIR="/usr/local/nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"
NVMPROFILE

# ===========================================================================
# 14. 构建完成：切换为中科大(USTC)软件源（rootfs 交付后国内使用）
#     注意：此处只改源，不再 apt-get update，避免从国外 runner 拉 USTC 变慢；
#           rootfs 首次启动后执行 apt-get update 即从中科大拉取索引。
# ===========================================================================
log "切换软件源为中科大(USTC)"
cat > /etc/apt/sources.list.d/ubuntu.sources <<FINALSRC
# Ubuntu 26.04 (Resolute Raccoon) arm64 —— 中科大(USTC)完整软件源
# 含 main / universe / restricted / multiverse 以及 updates / backports / security
Types: deb
URIs: ${FINAL_MIRROR}
Suites: ${RELEASE} ${RELEASE}-updates ${RELEASE}-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: ${FINAL_MIRROR}
Suites: ${RELEASE}-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

# 如需源码仓库，取消下面注释即可
# Types: deb-src
# URIs: ${FINAL_MIRROR}
# Suites: ${RELEASE} ${RELEASE}-updates ${RELEASE}-backports
# Components: main restricted universe multiverse
# Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
FINALSRC

# ===========================================================================
# 15. 收尾清理
# ===========================================================================
log "验证结果"
echo "OS   : $(. /etc/os-release && echo "$PRETTY_NAME")"
echo "架构 : $(uname -m)"
echo "zsh  : $(zsh --version)"
echo "node : $(node -v)"
echo "npm  : $(npm -v)"
echo "dsh  : $(dsh --version 2>/dev/null | head -n1 || echo '已安装')"

log "清理"
rm -f /usr/sbin/policy-rc.d
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -f /etc/machine-id
rm -f /var/lib/dbus/machine-id
rm -f /root/setup.sh

log "chroot 配置完成"
