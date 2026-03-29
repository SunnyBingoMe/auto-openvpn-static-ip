# auto-openvpn-static-ip

基于官方脚本改造。在 Linux/Ubuntu 上自动安装 OpenVPN，并在创建客户端时自动为该客户端生成 CCD 静态 IP 绑定。

## 快速开始

```bash
git clone https://github.com/SunnyBingoMe/auto-openvpn-static-ip.git
cd auto-openvpn-static-ip
sudo bash ./install-auto-openvpn.sh
```

## 效果

- 运行 `bash install-auto-openvpn.sh` 时，如果当前用户不是 root 但可以使用 `sudo`，脚本会自动提权继续执行。
- 如果检测到机器上已经存在 `/etc/openvpn/server` 安装，安装脚本会先询问是否覆盖；默认答案为覆盖。
- 覆盖现有安装时，会尽量保留当前客户端继续连接所依赖的状态，例如 `easy-rsa`/证书、`tc.key`、`client-pwd-auth`、`ccd-udp`、`ccd-tcp`、`ipp-udp.txt`、`ipp-tcp.txt`。
- 覆盖现有安装时，会重建辅助脚本和客户端模板中的派生行；例如会把 `pull-filter ignore dhcp-option DNS` 规范化为 `pull-filter ignore "dhcp-option DNS"`，但不会擅自猜测或改写已有模板中的 `remote` 终端地址。
- 安装完成后，OpenVPN 服务端配置和辅助脚本会放到 `/etc/openvpn` 体系下。
- 运行 `sudo auto-openvpn-add-client.sh my_client_name` 时，会自动：
  - 创建客户端证书和 `.ovpn` 配置文件
  - 询问客户端登录用户名（默认同客户端名）以及登录密码
  - 为该客户端生成 CCD 文件
  - 自动分配一个静态 VPN IP
- 客户端名允许字符为字母、数字、`-`、`_`；因为它既可能作为默认登录用户名和默认登录密码，也可能在选择 `n` 时作为内嵌到 `.ovpn` 的默认凭据
- 安装完成后，服务端会同时启用 UDP 和 TCP 两个 OpenVPN 监听；UDP 保持默认客户端导出协议，TCP 用于需要时显式导出。
- 为避免双实例共享同一地址池带来的冲突，UDP 默认使用 `172.22.0.0/16`，TCP 默认使用独立的 `172.23.0.0/16`。
- 安装脚本会自动下发对端子网路由，所以 `172.22.0.0/16` 与 `172.23.0.0/16` 默认互通。
- 如果是通过 `sudo` 由普通用户触发，生成的 `.ovpn` 会优先保存到该用户的 home 目录，并尽量保持归属该用户。
- 新生成的客户端配置默认使用分流模式：保留 VPN 网段访问，但忽略服务端推送的默认路由和 DNS。

## 安装后目录

- `/etc/openvpn/server/server-udp.conf`：UDP OpenVPN 服务端配置
- `/etc/openvpn/server/server-tcp.conf`：TCP OpenVPN 服务端配置
- `/etc/openvpn/server/client-common-udp-tcp.txt`：UDP/TCP 通用客户端模板
- `/etc/openvpn/server/to-get-from-hwdsl2.sh`：上游安装/客户端管理脚本
- `/etc/openvpn/server/auto-openvpn-add-client.sh`：客户端创建脚本
- `/etc/openvpn/server/openvpn-pwd-auth-verify.sh`：用户名密码校验脚本
- `/etc/openvpn/server/client-pwd-auth/`：客户端用户名密码存储目录
- `/etc/openvpn/server/to-assign-ip-to-client.sh`：CCD 静态 IP 分配脚本
- `/etc/openvpn/ccd-udp`：UDP 客户端 CCD 目录
- `/etc/openvpn/ccd-tcp`：TCP 客户端 CCD 目录
- `/etc/openvpn/client-udp-tcp`：未通过普通用户 `sudo` 调用时的 `.ovpn` 默认回退目录，也是安装后唯一保留的客户端 profile 目录
- `/usr/local/sbin/auto-openvpn-add-client.sh`：便于直接调用的命令入口

## 使用方式

### 1. 安装 OpenVPN

```bash
bash install-auto-openvpn.sh
#PS：测试通过的 Ubuntu 24.04.2 机器上 `apt` 安装到的 OpenVPN 版本是 `2.6.19`。
```

安装脚本会：

- 调用 `to-get-from-hwdsl2.sh --auto` 进行无人值守安装
- 生成显式命名的 `server-udp.conf`
- 基于 `server-udp.conf` 额外生成 `server-tcp.conf`，把 TCP 实例放到独立的 `172.23.0.0/16` 地址池和 `/etc/openvpn/ccd-tcp`，并启动 `openvpn-server@server-udp.service` 与 `openvpn-server@server-tcp.service`
- 自动向 UDP 客户端推送 `172.23.0.0/16` 路由，向 TCP 客户端推送 `172.22.0.0/16` 路由
- 创建 `/etc/openvpn/ccd-udp`、`/etc/openvpn/ccd-tcp` 和 `/etc/openvpn/client-udp-tcp`
- 创建 `client-common-udp-tcp.txt` 作为 UDP/TCP 通用客户端模板
- 清理上游额外生成但不属于双栈规范的产物，例如 `/etc/openvpn/server/server.conf`、`/etc/openvpn/server/client-common.txt`、`/etc/openvpn/client`、`/etc/systemd/system/openvpn-iptables.service` 以及 `/etc/rc.local` 中对该单栈 firewall unit 的重启注入
- 如果是覆盖已有安装，则在保留现有连接关键状态的前提下，按当前仓库逻辑规范化 `client-common-udp-tcp.txt` 中的派生配置行
- 设置相应权限
- 部署辅助脚本到 `/etc/openvpn/server`

### 2. 创建客户端并自动绑定静态 IP

默认导出 UDP 客户端：

```bash
sudo auto-openvpn-add-client.sh my_client_name
```

显式导出 TCP 客户端：

```bash
sudo auto-openvpn-add-client.sh --proto tcp my_client_name
```

执行后会：

- 当客户端证书不存在时，调用 `/etc/openvpn/server/to-get-from-hwdsl2.sh --addclient my_client_name`
- 当客户端证书已存在时，调用 `/etc/openvpn/server/to-get-from-hwdsl2.sh --exportclient my_client_name`
- 如果保持默认选项（要求客户端密码登录），则询问该客户端的 OpenVPN 登录用户名，默认值为 `my_client_name`
- 如果保持默认选项（要求客户端密码登录），则询问该客户端的 OpenVPN 登录密码；这些凭据会保存到服务端校验目录，客户端连接时需要手动输入，不会内嵌到导出的 `.ovpn` 中
- 如果保持默认选项（要求客户端密码登录）且用户名直接回车，则默认用户名为客户端名
- 如果保持默认选项（要求客户端密码登录）且两次密码都留空，则默认密码为客户端名
- 如果选择 `n`，则不会继续询问用户名和密码，而是直接使用客户端名作为默认用户名和默认密码，并将它们内嵌到 `.ovpn` 中，用来模拟 cert-only 的使用方式
- 调用 `/etc/openvpn/server/to-assign-ip-to-client.sh my_client_name`
- 在 `/etc/openvpn/ccd-udp/my_client_name` 写入类似下面的内容：

```conf
ifconfig-push 172.22.X.Y 255.255.0.0
```

- 将生成的客户端配置文件优先保存到当前 `sudo` 调用用户的 home 目录；如果拿不到该目录，则回退保存到：

```bash
/etc/openvpn/client-udp-tcp/my_client_name.udp.ovpn
```

如果导出 TCP 客户端，则输出文件名会变成：

```bash
/etc/openvpn/client-udp-tcp/my_client_name.tcp.ovpn
```

生成的客户端配置默认会包含：

```conf
auth-user-pass
ignore-unknown-option block-outside-dns block-ipv6
pull-filter ignore redirect-gateway
pull-filter ignore "dhcp-option DNS"
route-nopull
route 172.22.0.0 255.255.0.0
```

这意味着：

- 客户端仍会连上 VPN
- 客户端除了 `.ovpn` 内嵌证书外，如果服务端要求用户名密码登录，则会在连接时手动输入用户名和密码；只有选择 `n` 模拟 cert-only 时，`.ovpn` 才会额外内嵌默认用户名和密码
- 客户端可访问整个 `172.22.0.0/16` VPN 网段
- 客户端不会默认把所有流量走 VPN
- 客户端默认继续使用自己本机的 DNS
- 同一个客户端名在 UDP 和 TCP 下会分别写入 `/etc/openvpn/ccd-udp` 与 `/etc/openvpn/ccd-tcp`
- UDP 客户端默认访问 `172.22.0.0/16`，TCP 客户端默认访问 `172.23.0.0/16`
- UDP 与 TCP 两个 VPN 子网默认可以双向访问
- 同一个客户端名可以导出两份协议不同的 profile（`.udp.ovpn` / `.tcp.ovpn`），它们共享同一套客户端证书与私钥

注意：同一个客户端名的 UDP/TCP 配置设计上是“按需选择传输方式”，不是为了让同一个证书同时双连。
注意：`auto-openvpn-revoke-client.sh` 选择 `udp` 或 `tcp` 时，只删除该协议的 CCD / IPP / profile；只有选择 `all` 时，才会吊销共享证书并删除两侧 profile。

## 权限说明

- `install-auto-openvpn.sh` 和 `auto-openvpn-add-client.sh` 都支持在非 root 用户下通过 `sudo` 执行。
- `/etc/openvpn/server/auto-openvpn-add-client.sh`
- `/etc/openvpn/server/to-assign-ip-to-client.sh`
- `/etc/openvpn/server/to-get-from-hwdsl2.sh`
- `/etc/openvpn/ccd-udp`

- 管理脚本本身仍保持仅 root 可执行；但 OpenVPN 运行时需要读取的目录和文件（例如 `server-udp.conf`、`server-tcp.conf`、`client-common-udp-tcp.txt`、`ccd-udp`、`ccd-tcp`、`ipp-udp.txt`、`ipp-tcp.txt`）会设置为 `root:<OpenVPN runtime group>`，并给予 group 读取/遍历权限，避免 `user nobody` 的 server 进程无法访问。
- 默认情况下，这个 runtime group 通常是 `nogroup` 或 `nobody`，脚本会从服务端配置中的 `group` 指令自动探测；`client-pwd-auth` 目录和凭据文件仍保持更严格的 `750/640` 权限，只向该 runtime group 开放读取。

如果是通过 `sudo` 由普通用户创建客户端，生成的 `.ovpn` 会尽量归属该普通用户，而不是 `root`。

## 静态 IP 分配规则

- 默认网段前缀：`172.22`
- 默认起始主机号：`10`
- 默认结束主机号：`254`
- 默认子网掩码：`255.255.0.0`

默认情况下，脚本会在整个 `172.22.0.0/16` 地址池中寻找空闲 IP，而不是只在单个 `/24` 里分配。

可通过环境变量覆盖：

- `OPENVPN_SUBNET_PREFIX`
- `OPENVPN_START_HOST`
- `OPENVPN_END_HOST`
- `OPENVPN_MASK`
- `OPENVPN_IPP_FILE`

## 备注

- 本仓库基于 `to-get-from-hwdsl2.sh` 提供 OpenVPN 安装与客户端证书生成能力。
- 本仓库额外补上了 CCD 目录、静态 IP 分配和脚本部署逻辑。
- 当前默认 VPN 子网为 `172.22.0.0/16`。
- 旧版本生成的 `.ovpn` 文件和旧的 `/etc/openvpn/ccd-udp/*` 条目不会自动迁移到新网段；升级已有服务器后，需要按需手动更新旧客户端配置和旧 CCD 静态地址。

## 从旧 `10.8.0.0/24` 迁移到 `172.22.0.0/16`

如果服务器以前已经用旧网段运行过，可以直接用 `grep` 找出旧值，再用 `sed` 批量替换，不需要手工逐个改。

### 1. CCD 静态地址：先 grep，再直接 sed

先确认 `/etc/openvpn/ccd-udp` 里还有哪些旧的 `10.8.x.x`：

```bash
grep -R "10\.8\." /etc/openvpn/ccd-udp
```

确认后可直接批量替换旧前缀和旧掩码：

```bash
sudo find /etc/openvpn/ccd-udp -type f -exec sed -i 's/10\.8\./172.22./g; s/255\.255\.255\.0/255.255.0.0/g' {} +
```

### 2. ipp 记录：先 grep，再直接 sed

如果服务器上已有旧的 UDP 地址池持久化记录，也可以直接查并替换：

```bash
grep "10\.8\." /etc/openvpn/server/ipp-udp.txt
```

```bash
sudo sed -i 's/10\.8\./172.22./g' /etc/openvpn/server/ipp-udp.txt
```

(如果你更希望完全重新分配，也可以在停服务后先备份再清空 `ipp-udp.txt`，然后重新生成客户端。)

### 3. 重新生成客户端配置

旧版本生成的 `.ovpn` 文件里仍可能保留旧路由或旧访问假设。建议为仍在使用的客户端重新生成：

```bash
sudo auto-openvpn-add-client.sh my_client_name
sudo auto-openvpn-add-client.sh --proto tcp my_client_name
```

新生成的配置会默认使用：

- `route 172.22.0.0 255.255.0.0`
- 忽略服务端推送的默认路由
- 忽略服务端推送的 DNS

### 4. 重启 OpenVPN 服务

完成替换或重新生成后，重启服务使其生效：

```bash
sudo systemctl restart openvpn-server@server-udp.service
sudo systemctl restart openvpn-server@server-tcp.service
```

## 回归检查

```bash
bash tests/dual_protocol_contract.sh
bash tests/restore-smoke-test.sh
bash -n install-auto-openvpn.sh auto-openvpn-add-client.sh auto-openvpn-revoke-client.sh to-assign-ip-to-client.sh to-get-from-hwdsl2.sh backup-current-certs-and-basic-config.sh restore.sh compare-restore-state.sh
```

如果你已经另外准备好了旧服务器的本地快照，也可以额外对比旧服务器和新服务器恢复后的 `pwd-auth` / CCD / IPP 状态：

```bash
sudo bash compare-restore-state.sh <old-server-root> /
```

默认这是一个“只报告、不阻断”的辅助脚本；即使发现差异也默认退出 0。只有在显式设置 `STRICT_MODE=1` 时，发现差异才会返回非零退出码。

## 迁移到另一台 Ubuntu 服务器

如果目标服务器已经先运行过 `install-auto-openvpn.sh`，可以直接把旧服务器的证书、服务端配置和 CCD/IPP 状态打包后恢复到新服务器。

### 1. 在旧服务器生成备份包

```bash
sudo bash backup-current-certs-and-basic-config.sh
```

默认会在当前用户的 home 目录生成一个类似下面的文件：

```bash
~/openvpn-backup-2026-03-25_2318.tgz
```

备份成功后，脚本还会额外打印一个 best-effort 摘要，例如 `pwd-auth credential files`、UDP CCD 数量、TCP CCD 数量。这只是辅助核对信息；如果摘要统计失败，不会影响主备份包生成。

你也可以显式指定输出路径：

```bash
sudo bash backup-current-certs-and-basic-config.sh ~/openvpn-backup-2026-03-25_2318.tgz
```

备份包会保留：

- 现有 Easy-RSA/PKI 与服务端证书、密钥、`tc.key`
- `client-pwd-auth` 中的用户名密码校验文件
- UDP/TCP 服务端配置与客户端模板
- `ccd-udp`、`ccd-tcp` 和 `ipp-udp.txt`、`ipp-tcp.txt`
- 当前仓库部署到 `/etc/openvpn/server` 的辅助脚本
- 当前仓库生成的 OpenVPN 防火墙 systemd unit 和转发 sysctl 配置

### 2. 把备份包复制到新服务器

先在新服务器完成基础安装：

```bash
sudo bash install-auto-openvpn.sh
```

然后把旧服务器生成的 `.tgz` 复制到新服务器任意位置。

### 3. 在新服务器恢复

```bash
sudo bash restore.sh openvpn-backup-2026-03-25_2318.tgz
```

恢复脚本会：

- 先检查新服务器是否已经有 `install-auto-openvpn.sh` 生成的基础目录
- 停掉当前 OpenVPN UDP/TCP 实例和防火墙 service
- 先备份新服务器当前 `/etc/openvpn` 相关状态到 `/root/openvpn-restore-backup-时间戳`
- 覆盖恢复旧服务器的证书、配置、CCD、IPP 和辅助脚本
- 在真正开始 restore 前，先尝试通过 `cip.cc`、`ifconfig.co` 自动探测当前服务器的公网 IP，并让你确认；如果你输入 `n`，或者自动探测全部失败，脚本会要求你手动输入合法的公网 IPv4 或域名。确认后的地址会写回 `client-common-udp-tcp.txt` 的 `remote`，避免后续新导出的 `.ovpn` 继续沿用旧服务器地址；也可以直接通过 `OPENVPN_RESTORE_PUBLIC_ENDPOINT` 跳过探测与确认
- 重新部署当前仓库约定的目录与服务并重新启动服务
- 输出一组仍需你手工确认的事项，包括旧客户端 `.ovpn` 是否已改成新服务器地址，以及外围防火墙是否已放行 OpenVPN 监听端口和 VPN 转发回包路径

### 4. 运行恢复后的 smoke test

```bash
sudo bash tests/restore-smoke-test.sh
```

这个脚本会自动检查，并在发现硬性失败项时返回非零退出码：

- UDP/TCP OpenVPN 服务和 repo 生成的 firewall services 是否处于 active
- UDP/TCP 监听端口是否处于 listening 状态
- `server-udp.conf`、`server-tcp.conf`、`client-common-udp-tcp.txt`、`easy-rsa`、CCD、IPP、证书和 `tc.key` 是否齐全
- `client-common-udp-tcp.txt` 是否已经写入当前服务器的 `remote <endpoint> <port>`
- 当前目录、文件和服务名是否仍然符合 repo 约定的位置
- `net.ipv4.ip_forward` 是否已经打开
- `pwd-auth` 校验脚本和 `client-pwd-auth` 目录是否存在，并具备 restore.sh 期望的权限/属组

注意：如果 `client-pwd-auth` 目录为空，smoke test 会给出 warning。只有当旧服务器本来就没有这类凭据文件时，这个 warning 才是可接受的；否则说明密码登录相关数据没有完整迁移。脚本会对目录、校验脚本以及抽样凭据文件做权限/属组检查，但不会实际发起一次密码认证。

如果你已经用别的方式准备好了旧服务器的本地目录快照，还可以再运行一次 best-effort 对比：

```bash
sudo bash compare-restore-state.sh /mnt/old-server /
```

它会比较：

- `client-pwd-auth` 下每个文件的内容 hash
- `ccd-udp` / `ccd-tcp` 下每个文件的内容 hash
- `ipp-udp.txt` / `ipp-tcp.txt` 整个文件的 hash

这个对比脚本默认不会阻断你的主流程；如果你想在 CI 或严格核对场景里把差异当成失败，再显式加上：

```bash
sudo STRICT_MODE=1 bash compare-restore-state.sh /mnt/old-server /
```

### 5. 客户端如何切换

在该迁移方式下，客户端通常不需要重新签发证书。只要旧服务器和新服务器之间恢复的是同一套 CA、server cert、`tc.key` 与服务端配置，现有客户端通常只需要把 `.ovpn` 里的 `remote` IP 改成新服务器 IP 即可重新连接。

如果客户端原来使用的是域名而不是 IP，那么只需要把 DNS 指向新服务器即可，客户端配置文件本身甚至不需要改。
