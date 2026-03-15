# auto-openvpn-static-ip

在 Ubuntu 上自动安装 OpenVPN，并在创建客户端时自动为该客户端生成 CCD 静态 IP 绑定。

## 效果

- 运行 `bash install.sh` 时，如果当前用户不是 root 但可以使用 `sudo`，脚本会自动提权继续执行。
- 安装完成后，OpenVPN 服务端配置和辅助脚本会放到 `/etc/openvpn` 体系下。
- 运行 `create_ovpn_client.sh my_client_name` 时，会自动：
  - 创建客户端证书和 `.ovpn` 配置文件
  - 为该客户端生成 CCD 文件
  - 自动分配一个静态 VPN IP
- 新生成的客户端配置默认使用分流模式：保留 VPN 网段访问，但忽略服务端推送的默认路由和 DNS。

## 安装后目录

- `/etc/openvpn/server/server.conf`：OpenVPN 服务端配置
- `/etc/openvpn/server/official-auto-install.sh`：上游安装/客户端管理脚本
- `/etc/openvpn/server/create_ovpn_client.sh`：客户端创建脚本
- `/etc/openvpn/server/assign_vpn_ip.sh`：CCD 静态 IP 分配脚本
- `/etc/openvpn/ccd`：客户端 CCD 目录
- `/etc/openvpn/client`：生成后的客户端 `.ovpn` 文件目录
- `/usr/local/sbin/create_ovpn_client.sh`：便于直接调用的命令入口

## 使用方式

### 1. 安装 OpenVPN

```bash
bash install.sh
```

安装脚本会：

- 调用 `official-auto-install.sh --auto` 进行无人值守安装
- 确保 `server.conf` 中包含 `client-config-dir /etc/openvpn/ccd`
- 创建 `/etc/openvpn/ccd` 和 `/etc/openvpn/client`
- 设置相应权限
- 部署辅助脚本到 `/etc/openvpn/server`

### 2. 创建客户端并自动绑定静态 IP

```bash
create_ovpn_client.sh my_client_name
```

执行后会：

- 调用 `/etc/openvpn/server/official-auto-install.sh --addclient my_client_name`
- 调用 `/etc/openvpn/server/assign_vpn_ip.sh my_client_name`
- 在 `/etc/openvpn/ccd/my_client_name` 写入类似下面的内容：

```conf
ifconfig-push 172.22.X.Y 255.255.0.0
```

- 将生成的客户端配置文件保存到：

```bash
/etc/openvpn/client/my_client_name.ovpn
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

## 权限说明

- `install.sh` 和 `create_ovpn_client.sh` 都支持在非 root 用户下执行，只要该用户可以使用 `sudo`。
- `/etc/openvpn/server/create_ovpn_client.sh`
- `/etc/openvpn/server/assign_vpn_ip.sh`
- `/etc/openvpn/server/official-auto-install.sh`

以上脚本安装后会设置为仅 root 可执行。

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
- 旧版本生成的 `.ovpn` 文件和旧的 `/etc/openvpn/ccd/*` 条目不会自动迁移到新网段；升级已有服务器后，需要按需手动更新旧客户端配置和旧 CCD 静态地址。

## 从旧 `10.8.0.0/24` 迁移到 `172.22.0.0/16`

如果服务器以前已经用旧网段运行过，可以直接用 `grep` 找出旧值，再用 `sed` 批量替换，不需要手工逐个改。

### 1. CCD 静态地址：先 grep，再直接 sed

先确认 `/etc/openvpn/ccd` 里还有哪些旧的 `10.8.x.x`：

```bash
grep -R "10\.8\." /etc/openvpn/ccd
```

确认后可直接批量替换旧前缀和旧掩码：

```bash
sudo find /etc/openvpn/ccd -type f -exec sed -i 's/10\.8\./172.22./g; s/255\.255\.255\.0/255.255.0.0/g' {} +
```

### 2. ipp 记录：先 grep，再直接 sed

如果服务器上已有旧的地址池持久化记录，也可以直接查并替换：

```bash
grep "10\.8\." /etc/openvpn/server/ipp.txt
```

```bash
sudo sed -i 's/10\.8\./172.22./g' /etc/openvpn/server/ipp.txt
```

(如果你更希望完全重新分配，也可以在停服务后先备份再清空 `ipp.txt`，然后重新生成客户端。)

### 3. 重新生成客户端配置

旧版本生成的 `.ovpn` 文件里仍可能保留旧路由或旧访问假设。建议为仍在使用的客户端重新生成：

```bash
create_ovpn_client.sh my_client_name
```

新生成的配置会默认使用：

- `route 172.22.0.0 255.255.0.0`
- 忽略服务端推送的默认路由
- 忽略服务端推送的 DNS

### 4. 重启 OpenVPN 服务

完成替换或重新生成后，重启服务使其生效：

```bash
sudo systemctl restart openvpn-server@server.service
```
