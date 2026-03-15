# auto-openvpn-static-ip

在 Ubuntu 上自动安装 OpenVPN，并在创建客户端时自动为该客户端生成 CCD 静态 IP 绑定。

## 效果

- 运行 `bash install.sh` 时，如果当前用户不是 root 但可以使用 `sudo`，脚本会自动提权继续执行。
- 安装完成后，OpenVPN 服务端配置和辅助脚本会放到 `/etc/openvpn` 体系下。
- 运行 `create_ovpn_client.sh my_client_name` 时，会自动：
  - 创建客户端证书和 `.ovpn` 配置文件
  - 为该客户端生成 CCD 文件
  - 自动分配一个静态 VPN IP

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
ifconfig-push 10.8.0.X 255.255.255.0
```

- 将生成的客户端配置文件保存到：

```bash
/etc/openvpn/client/my_client_name.ovpn
```

## 权限说明

- `install.sh` 和 `create_ovpn_client.sh` 都支持在非 root 用户下执行，只要该用户可以使用 `sudo`。
- `/etc/openvpn/server/create_ovpn_client.sh`
- `/etc/openvpn/server/assign_vpn_ip.sh`
- `/etc/openvpn/server/official-auto-install.sh`

以上脚本安装后会设置为仅 root 可执行。

## 静态 IP 分配规则

- 默认网段前缀：`10.8.0`
- 默认起始主机号：`10`
- 默认结束主机号：`254`
- 默认子网掩码：`255.255.255.0`

可通过环境变量覆盖：

- `OPENVPN_SUBNET_PREFIX`
- `OPENVPN_START_HOST`
- `OPENVPN_END_HOST`
- `OPENVPN_MASK`
- `OPENVPN_IPP_FILE`

## 备注

- 本仓库基于 `official-auto-install.sh` 提供 OpenVPN 安装与客户端证书生成能力。
- 本仓库额外补上了 CCD 目录、静态 IP 分配和脚本部署逻辑。
