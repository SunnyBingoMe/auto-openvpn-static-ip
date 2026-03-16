# auto-openvpn-static-ip

基于官方脚本改造。在 Linux/Ubuntu 上自动安装 OpenVPN，并在创建客户端时自动为该客户端生成 CCD 静态 IP 绑定。

## 快速开始

```bash
git clone https://github.com/SunnyBingoMe/auto-openvpn-static-ip.git
cd auto-openvpn-static-ip
sudo sh ./install.sh
```

## 效果

- 运行 `bash install.sh` 时，如果当前用户不是 root 但可以使用 `sudo`，脚本会自动提权继续执行。
- 安装完成后，OpenVPN 服务端配置和辅助脚本会放到 `/etc/openvpn` 体系下。
- 运行 `sudo create_ovpn_client.sh my_client_name` 时，会自动：
  - 创建客户端证书和 `.ovpn` 配置文件
  - 为该客户端生成 CCD 文件
  - 自动分配一个静态 VPN IP
- 安装完成后，服务端会同时启用 UDP 和 TCP 两个 OpenVPN 监听；UDP 保持默认客户端导出协议，TCP 用于需要时显式导出。
- 为避免双实例共享同一地址池带来的冲突，UDP 默认使用 `172.22.0.0/16`，TCP 默认使用独立的 `172.23.0.0/16`。
- 安装脚本会自动下发对端子网路由，所以 `172.22.0.0/16` 与 `172.23.0.0/16` 默认互通。
- 如果是通过 `sudo` 由普通用户触发，生成的 `.ovpn` 会优先保存到该用户的 home 目录，并尽量保持归属该用户。
- 新生成的客户端配置默认使用分流模式：保留 VPN 网段访问，但忽略服务端推送的默认路由和 DNS。

## 安装后目录

- `/etc/openvpn/server/server-udp.conf`：UDP OpenVPN 服务端配置
- `/etc/openvpn/server/server-tcp.conf`：TCP OpenVPN 服务端配置
- `/etc/openvpn/server/client-common-udp-tcp.txt`：UDP/TCP 通用客户端模板
- `/etc/openvpn/server/official-auto-install.sh`：上游安装/客户端管理脚本
- `/etc/openvpn/server/create_ovpn_client.sh`：客户端创建脚本
- `/etc/openvpn/server/assign_vpn_ip.sh`：CCD 静态 IP 分配脚本
- `/etc/openvpn/ccd-udp`：UDP 客户端 CCD 目录
- `/etc/openvpn/ccd-tcp`：TCP 客户端 CCD 目录
- `/etc/openvpn/client-udp-tcp`：未通过普通用户 `sudo` 调用时的 `.ovpn` 默认回退目录
- `/usr/local/sbin/create_ovpn_client.sh`：便于直接调用的命令入口

## 使用方式

### 1. 安装 OpenVPN

```bash
bash install.sh
```

安装脚本会：

- 调用 `official-auto-install.sh --auto` 进行无人值守安装
- 把上游默认生成的 `server.conf` 收敛为显式命名的 `server-udp.conf`，并保留兼容软链
- 基于 `server-udp.conf` 额外生成 `server-tcp.conf`，把 TCP 实例放到独立的 `172.23.0.0/16` 地址池和 `/etc/openvpn/ccd-tcp`，并启动 `openvpn-server@server-udp.service` 与 `openvpn-server@server-tcp.service`
- 自动向 UDP 客户端推送 `172.23.0.0/16` 路由，向 TCP 客户端推送 `172.22.0.0/16` 路由
- 创建 `/etc/openvpn/ccd-udp`、`/etc/openvpn/ccd-tcp` 和 `/etc/openvpn/client-udp-tcp`，并保留兼容软链
- 创建 `client-common-udp-tcp.txt` 作为 UDP/TCP 通用客户端模板，并保留兼容软链
- 设置相应权限
- 部署辅助脚本到 `/etc/openvpn/server`

### 2. 创建客户端并自动绑定静态 IP

默认导出 UDP 客户端：

```bash
sudo create_ovpn_client.sh my_client_name
```

显式导出 TCP 客户端：

```bash
sudo create_ovpn_client.sh --proto tcp my_client_name
```

执行后会：

- 当客户端证书不存在时，调用 `/etc/openvpn/server/official-auto-install.sh --addclient my_client_name`
- 当客户端证书已存在时，调用 `/etc/openvpn/server/official-auto-install.sh --exportclient my_client_name`
- 调用 `/etc/openvpn/server/assign_vpn_ip.sh my_client_name`
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
ignore-unknown-option block-outside-dns block-ipv6
pull-filter ignore redirect-gateway
pull-filter ignore dhcp-option DNS
route-nopull
route 172.22.0.0 255.255.0.0
```

这意味着：

- 客户端仍会连上 VPN
- 客户端可访问整个 `172.22.0.0/16` VPN 网段
- 客户端不会默认把所有流量走 VPN
- 客户端默认继续使用自己本机的 DNS
- 同一个客户端名在 UDP 和 TCP 下会分别写入 `/etc/openvpn/ccd-udp` 与 `/etc/openvpn/ccd-tcp`
- UDP 客户端默认访问 `172.22.0.0/16`，TCP 客户端默认访问 `172.23.0.0/16`
- UDP 与 TCP 两个 VPN 子网默认可以双向访问

注意：同一个客户端名的 UDP/TCP 配置设计上是“按需选择传输方式”，不是为了让同一个证书同时双连。

## 权限说明

- `install.sh` 和 `create_ovpn_client.sh` 都支持在非 root 用户下通过 `sudo` 执行。
- `/etc/openvpn/server/create_ovpn_client.sh`
- `/etc/openvpn/server/assign_vpn_ip.sh`
- `/etc/openvpn/server/official-auto-install.sh`
- `/etc/openvpn/ccd-udp`

以上脚本和 CCD 目录安装后会设置为仅 root 可访问。

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

- 本仓库基于 `official-auto-install.sh` 提供 OpenVPN 安装与客户端证书生成能力。
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
sudo create_ovpn_client.sh my_client_name
sudo create_ovpn_client.sh --proto tcp my_client_name
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
bash -n install.sh create_ovpn_client.sh assign_vpn_ip.sh official-auto-install.sh
```
