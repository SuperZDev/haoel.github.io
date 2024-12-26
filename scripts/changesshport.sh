#!/bin/bash

# 设置新的SSH端口
NEW_PORT=19366

# 检查是否以root权限运行
if [ "$EUID" -ne 0 ]; then 
    echo "请以root权限运行此脚本"
    echo "使用方法: sudo bash change_ssh_port.sh"
    exit 1
fi

# 备份原始配置文件
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

# 修改SSH端口
sed -i "s/#\?Port [0-9]*/Port $NEW_PORT/" /etc/ssh/sshd_config

# 检查是否安装了ufw
if command -v ufw >/dev/null 2>&1; then
    # 允许新端口通过防火墙
    ufw allow $NEW_PORT/tcp
    echo "已添加防火墙规则"
fi

# 测试配置文件语法
sshd -t
if [ $? -ne 0 ]; then
    echo "SSH配置文件有误，正在还原备份..."
    cp /etc/ssh/sshd_config.backup /etc/ssh/sshd_config
    systemctl restart sshd
    exit 1
fi

# 重启SSH服务
systemctl restart sshd

# 验证新端口是否生效
if netstat -tlnp | grep ":$NEW_PORT.*sshd" >/dev/null; then
    echo "SSH端口已成功更改为 $NEW_PORT"
    echo "请使用新端口尝试连接: ssh username@host -p $NEW_PORT"
else
    echo "端口更改可能失败，请检查系统日志"
    echo "正在还原备份..."
    cp /etc/ssh/sshd_config.backup /etc/ssh/sshd_config
    systemctl restart sshd
fi
