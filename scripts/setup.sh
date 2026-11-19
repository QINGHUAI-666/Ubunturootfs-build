#!/usr/bin/env bash
# =============================================================================
#  在 Docker 容器内运行：把 Arch Linux ARM 官方 rootfs 配置成完整可用的 rootfs
#    - 构建期用官方 Arch ARM 源，配置完成后切换为中科大(USTC)源
#    - 附加源：archlinuxcn（中科大） + arch4edu（南京大学）
#    - 中文本地化（zh_CN.UTF-8）
#    - 常用工具
#    - root / Arch 用户、sudo 免密、OpenSSH 密码登录
#    - systemd（默认 multi-user、启用 sshd 服务）
#    - zsh + powerlevel10k（仅左侧、Nerd Font 图标）+ 插件
#    - 美观的启动欢迎语
# =============================================================================
set -euo pipefail

export HOME=/root
export LANG=C.UTF-8
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

ARCH="aarch64"
# 最终主源：中科大（rootfs 交付后国内使用）
FINAL_MIRROR="https://mirrors.ustc.edu.cn/archlinuxarm"
# 附加源
CN_MIRROR="https://mirrors.ustc.edu.cn/archlinuxcn"
EDU_MIRROR="https://mirror.nju.edu.cn/arch4edu"

log() { printf '\033[1;36m[setup]\033[0m %s\n' "$*"; }

# ===========================================================================
# 1. 构建期主源（官方 Arch ARM 源，与 GitHub runner 同区域，快）
# ===========================================================================
log "配置构建期主源（官方 Arch ARM）"
cat > /etc/pacman.d/mirrorlist <<'MIRROR'
Server = http://mirror.archlinuxarm.org/$arch/$repo
MIRROR

# 临时禁用 pacman 下载沙箱：Docker 容器 seccomp 会拦截 Landlock，
# 否则报 "Landlock ruleset could not be applied / switching to sandbox user 'alpm' failed"。
# 注意：这是构建期临时配置，收尾时会移除，恢复 pacman 默认沙箱（保持 rootfs 原样/安全）。
log "临时禁用 pacman 下载沙箱（容器内 Landlock 不可用）"
if grep -q '^DisableSandbox' /etc/pacman.conf; then
  :
elif grep -q '^#\s*DisableSandbox' /etc/pacman.conf; then
  sed -i 's/^#\s*DisableSandbox/DisableSandbox/' /etc/pacman.conf
else
  sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
fi

# 官方 rootfs 的 pacman keyring 处于未初始化状态（无 trustdb/本地主密钥），
# 必须先 --init 再 --populate，否则报 "Use 'pacman-key --init'" + "keyring is not writable"。
log "初始化 pacman keyring (pacman-key --init)"
pacman-key --init

log "导入 Arch Linux ARM / Arch Linux 官方签名密钥"
pacman-key --populate archlinuxarm archlinux

# 先刷新 keyring 包本身（避免旧 keyring 导致后续签名失败）
log "更新 keyring 包"
pacman -Sy --noconfirm archlinux-keyring archlinuxarm-keyring

log "pacman -Syu 更新系统"
pacman -Syu --noconfirm

# ===========================================================================
# 1.5 卸载实体机/裸机专用包
#     DroidSpaces 是 proot 容器，使用宿主内核，rootfs 内不需要：
#       内核、内核头文件、initramfs 生成器、各类固件、TPM、防火墙、控制台外设
# ===========================================================================
log "卸载实体机专用包（内核/固件/initramfs/TPM/防火墙/控制台外设）"

# 逐个卸载，先检查是否已安装，避免包名不存在导致 pacman 报错
_rm_pkg() {
  if pacman -Qi "$1" >/dev/null 2>&1; then
    log "  卸载 $1"
    pacman -Rns --noconfirm "$1" || log "  !! $1 卸载失败（已忽略）"
  fi
}

# 1) initramfs 生成器（先删，避免删除内核时触发 mkinitcpio 的 hook）
_rm_pkg mkinitcpio
_rm_pkg mkinitcpio-busybox

# 2) 内核 + 内核头文件（proot 用宿主内核）
_rm_pkg linux-aarch64
_rm_pkg linux-api-headers

# 3) 全部固件包（通配删除所有 linux-firmware*，含 amd/amdgpu/atheros/broadcom/
#    cirrus/intel/mediatek/mellanox/nvidia/qcom/radeon/realtek/ti/whence 等）
for _p in $(pacman -Qq 2>/dev/null | grep '^linux-firmware' || true); do
  _rm_pkg "$_p"
done

# 4) TPM 芯片支持（systemd/cryptsetup 均仅为可选依赖，删之无碍）
_rm_pkg tpm2-tss

# 5) 防火墙（proot 下无法配置 netfilter，nftables 无用）
_rm_pkg nftables
_rm_pkg libnftnl

# 6) 控制台鼠标 / DHCP 客户端
_rm_pkg gpm
_rm_pkg dhcpcd

# ===========================================================================
# 2. 基础系统组件
# ===========================================================================
log "安装基础系统组件"
pacman -S --noconfirm --needed \
  base-devel systemd \
  openssh sudo \
  zsh zsh-completions bash-completion \
  git curl wget \
  gnupg \
  man-db man-pages less file

# ===========================================================================
# 3. 中文本地化
# ===========================================================================
log "配置中文本地化环境"
sed -i 's/^#\s*\(zh_CN.UTF-8 UTF-8\)/\1/' /etc/locale.gen || true
sed -i 's/^#\s*\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen || true
grep -q '^zh_CN.UTF-8 UTF-8' /etc/locale.gen || echo 'zh_CN.UTF-8 UTF-8' >> /etc/locale.gen
grep -q '^en_US.UTF-8 UTF-8' /etc/locale.gen || echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
locale-gen

cat > /etc/locale.conf <<'LOCALE'
LANG=zh_CN.UTF-8
LC_CTYPE=zh_CN.UTF-8
LOCALE

# 时区：上海
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

# ===========================================================================
# 4. 常用工具
# ===========================================================================
log "安装常用工具"
pacman -S --noconfirm --needed \
  python python-pip \
  vim nano \
  htop btop \
  tmux \
  rsync \
  unzip zip \
  tree jq \
  ripgrep fd fzf zoxide bat eza \
  lsof strace \
  net-tools iproute2 iputils bind-tools \
  procps-ng ncdu duf aria2

# ===========================================================================
# 5. 用户与密码
# ===========================================================================
log "创建用户并设置密码"
echo "root:123456" | chpasswd

# 删除 Arch Linux ARM 官方 rootfs 自带的 alarm 用户
userdel -r alarm 2>/dev/null || true

# 确保附加组存在
for _g in wheel sudo audio video storage optical input lp power network; do
  getent group "$_g" >/dev/null 2>&1 || groupadd "$_g" || true
done

id -u Arch >/dev/null 2>&1 || useradd -m -G wheel,audio,video,storage,optical,input,lp,power,network -s /bin/zsh Arch
echo "Arch:123456" | chpasswd

# sudo 免密（wheel 组 + root）
cat > /etc/sudoers.d/10-nopasswd <<'SUDOERS'
%wheel ALL=(ALL:ALL) NOPASSWD:ALL
root ALL=(ALL:ALL) ALL
SUDOERS
chmod 0440 /etc/sudoers.d/10-nopasswd
grep -q '^@includedir /etc/sudoers.d' /etc/sudoers || echo '@includedir /etc/sudoers.d' >> /etc/sudoers

# 默认 shell 统一为 zsh
usermod -s /bin/zsh root
usermod -s /bin/zsh Arch

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

cat > /etc/ssh/sshd_config <<'SSHD'
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
Subsystem sftp /usr/lib/ssh/sftp-server
SSHD

# ===========================================================================
# 8. systemd
# ===========================================================================
log "配置 systemd"
ln -sf /usr/lib/systemd/system/multi-user.target /etc/systemd/system/default.target

# 容器内 systemctl 无法连接 systemd，手动建立 wants 符号链接来“启用”服务
enable_svc() {
  local unit="$1" src=""
  for p in /etc/systemd/system /usr/lib/systemd/system; do
    [ -f "$p/$unit" ] && { src="$p/$unit"; break; }
  done
  [ -z "$src" ] && { echo "!! 未找到单元 $unit"; return 1; }
  mkdir -p /etc/systemd/system/multi-user.target.wants
  ln -sf "$src" "/etc/systemd/system/multi-user.target.wants/$unit"
  echo "启用 $unit"
}
enable_svc sshd.service

# ===========================================================================
# 9. 启动欢迎语（美观 + 实用：展示系统/网络/资源信息）
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
: "${PRETTY_NAME:=Arch Linux}"
HOST="$(hostname 2>/dev/null || echo localhost)"
U="$(id -un 2>/dev/null || echo "${USER:-unknown}")"

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -z "$IP" ] && IP="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
[ -z "$IP" ] && IP="未分配"

KERNEL="$(uname -r 2>/dev/null || echo '-')"
ARCH="$(uname -m 2>/dev/null || echo '-')"
UP="$(uptime -p 2>/dev/null | sed 's/^up *//')"; [ -z "$UP" ] && UP="刚刚启动"
LOAD="$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"; [ -z "$LOAD" ] && LOAD="-"

# 内存：直接从 /proc/meminfo 读取（单位 kB），不依赖 free 命令（proot/DroidSpaces 下更可靠）
MEM=""
if [ -r /proc/meminfo ]; then
  _mt=$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null)
  _ma=$(awk '/^MemAvailable:/{print $2; exit}' /proc/meminfo 2>/dev/null)
  [ -z "$_ma" ] && _ma=$(awk '/^MemFree:/{print $2; exit}' /proc/meminfo 2>/dev/null)
  if [ -n "$_mt" ] && [ -n "$_ma" ] && [ "$_mt" -gt 0 ] 2>/dev/null; then
    _mu=$(( _mt - _ma ))
    MEM="$(awk -v u="$_mu" -v t="$_mt" 'BEGIN{printf "%.1fG / %.1fG (%.0f%%)", u/1048576, t/1048576, (t>0?u/t*100:0)}')"
  fi
fi
[ -z "$MEM" ] && MEM="未检测到"

# 磁盘：-P 保证一行一个文件系统，避免设备名过长折行导致取错行
DISK="$(df -hP / 2>/dev/null | awk 'NR==2{printf "%s / %s (%s)", $3, $2, $5}')"; [ -z "$DISK" ] && DISK="未检测到"
NPROC="$(nproc 2>/dev/null)"; [ -z "$NPROC" ] && NPROC="-"

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
printf '%s\n' "  ${DIM}${CYN}╰─ ${GRY}常用别名 ll / la / lt · 欢迎使用${R}"
printf '\n'
WELCOME
chmod 0755 /usr/local/bin/welcome

# 禁用系统 MOTD，避免与欢迎语重复显示
rm -f /etc/motd
: > /etc/motd

# ===========================================================================
# 10. zsh 主题（powerlevel10k，仅左侧 + Nerd Font 图标）与插件
# ===========================================================================
log "安装 zsh 主题与插件"
# 插件（官方仓库）：自动建议 / 语法高亮 / 补全
pacman -S --noconfirm --needed zsh-autosuggestions zsh-syntax-highlighting zsh-completions

# powerlevel10k（AUR 不在官方仓库，直接 git clone）
mkdir -p /usr/share/zsh
git clone --depth 1 https://github.com/romkatv/powerlevel10k.git /usr/share/zsh/powerlevel10k

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
# /etc/zsh/zshrc —— 系统级 zsh 配置（Arch Linux ARM · DroidSpaces）

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
[ -d /usr/share/zsh/site-functions ] && fpath=(/usr/share/zsh/site-functions $fpath)
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
if [ -f /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh ]; then
  source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
fi
ZSH_AUTOSUGGEST_STRATEGY=(history completion)
ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=20
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=#8a919c"
if [ -f /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]; then
  source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
fi

# ---------- 主题（powerlevel10k，仅左侧） ----------
# 关闭即时提示：在 DroidSpaces/headless 无缓存环境下更稳妥
typeset -g POWERLEVEL9K_INSTANT_PROMPT=off
[ -f /usr/share/zsh/powerlevel10k/powerlevel10k.zsh-theme ] && source /usr/share/zsh/powerlevel10k/powerlevel10k.zsh-theme
[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh

# ---------- 现代 CLI 工具 ----------
command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init zsh)"
command -v fzf >/dev/null 2>&1 && [ -f /usr/share/fzf/key-bindings.zsh ] && source /usr/share/fzf/key-bindings.zsh
command -v fzf >/dev/null 2>&1 && [ -f /usr/share/fzf/completion.zsh ] && source /usr/share/fzf/completion.zsh

# ---------- 别名（ls 带图标等） ----------
alias ls='eza --icons --group-directories-first --color=auto'
alias ll='eza -l --icons --group-directories-first --git --color=auto'
alias la='eza -la --icons --group-directories-first --git --color=auto'
alias lt='eza --tree --level=2 --icons --color=auto'
alias l='eza -1 --icons --color=auto'
alias cat='bat --paging=never --style=plain'
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
for h in /root /home/Arch; do
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
chown -R Arch:Arch /home/Arch

# bash 兜底配置
cat >> /etc/bash.bashrc <<'BASHRC'

# ---------- DroidSpaces 追加配置 ----------
command -v eza >/dev/null 2>&1 && {
  alias ls='eza --icons --group-directories-first --color=auto'
  alias ll='eza -l --icons --group-directories-first --git --color=auto'
  alias la='eza -la --icons --group-directories-first --git --color=auto'
}
command -v bat >/dev/null 2>&1 && alias cat='bat --paging=never --style=plain'

case $- in
  *i*) command -v welcome >/dev/null 2>&1 && welcome ;;
esac
BASHRC

# ===========================================================================
# 11. 附加软件源：archlinuxcn（中科大） + arch4edu（南京大学）
# ===========================================================================
log "配置附加软件源 archlinuxcn(中科大) + arch4edu(南京大学)"

cat >> /etc/pacman.conf <<CNREPO

[archlinuxcn]
Server = ${CN_MIRROR}/\$arch
CNREPO

# 安装 archlinuxcn-keyring 导入 GPG key（该包由 Arch 开发者签名，可直接验签安装）
pacman -Sy --noconfirm archlinuxcn-keyring

cat >> /etc/pacman.conf <<EDUREPO

[arch4edu]
Server = ${EDU_MIRROR}/\$arch
SigLevel = Optional TrustAll
EDUREPO

# 尝试导入 arch4edu 官方 GPG key（Key-ID 7931B6D628C8D3BA）
pacman-key --recv-keys 7931B6D628C8D3BA 2>/dev/null || true
pacman-key --lsign-key 7931B6D628C8D3BA 2>/dev/null || true

# ===========================================================================
# 12. 构建完成：切换主源为中科大（rootfs 交付后国内使用）
# ===========================================================================
log "切换主源为中科大(USTC)"
cat > /etc/pacman.d/mirrorlist <<FINALMIRROR
# Arch Linux ARM ($ARCH) —— 中科大(USTC)软件源
Server = ${FINAL_MIRROR}/\$arch/\$repo
FINALMIRROR

# ===========================================================================
# 13. 收尾清理
# ===========================================================================
log "验证结果"
echo "OS   : $(. /etc/os-release && echo "$PRETTY_NAME")"
echo "架构 : $(uname -m)"
echo "zsh  : $(zsh --version)"

# 移除构建期临时加入的 DisableSandbox，恢复 pacman 默认沙箱配置（交付后保持原样）
log "恢复 pacman 默认沙箱配置"
if grep -q '^DisableSandbox' /etc/pacman.conf; then
  sed -i 's/^DisableSandbox/#DisableSandbox/' /etc/pacman.conf
fi

log "清理"
pacman -Scc --noconfirm 2>/dev/null || true
rm -f /etc/machine-id
rm -f /var/lib/systemd/random-seed
rm -rf /var/cache/pacman/pkg/*
rm -f /root/setup.sh

log "容器内配置完成"
