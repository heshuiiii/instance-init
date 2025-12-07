# instance-init
heshui常用脚本

## 安装多个qbittorrent刷流
```
bash <(wget -qO- https://raw.githubusercontent.com/heshuiiii/Dedicated-Seedbox/refs/heads/main/Install.sh) -u 用户名 -p 密码 -c -1 -q 4.3.9 -l v1.2.20
wget -O tcp.sh "https://git.io/coolspeeda" && chmod +x tcp.sh && ./tcp.sh
wget -O mult_qb_enhanced.sh "https://raw.githubusercontent.com/heshuiiii/instance-init/refs/heads/main/qbittorrent_mult/mult_qb_enhanced.sh" && bash mult_qb_enhanced.sh
```

## 初始化服务器
```
wget -O init_debian_with_rclone.sh "https://raw.githubusercontent.com/heshuiiii/instance-init/refs/heads/main/init_debian_with_rclone.sh" && bash init_debian_with_rclone.sh
wget -O init_debian_with_rclone.sh "https://raw.githubusercontent.com/heshuiiii/instance-init/refs/heads/main/init_debian_with_rclone.sh" && bash init_debian_with_rclone.sh --host Netcup --locale --tz Asia/Shanghai

```
```
wget -O smb_auto_config.sh "https://raw.githubusercontent.com/heshuiiii/instance-init/refs/heads/main/smb_auto_config.sh" && bash smb_auto_config.sh
```




