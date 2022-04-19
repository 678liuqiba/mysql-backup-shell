## 说明
若项目只部署在一台服务器上, 又纠结数据库备份时对数据库资源的占用, 那么此脚本有一定用处
## 容器创建
```
sudo docker run -itd --name mysql_slave \
-v /home/mysql_slave/data:/home/data -e MYSQL_ROOT_PASSWORD=[PASSWORD] \
 --network-alias mysql_slave --ip 172.20.0.5 --network bridge_20 \
--restart unless-stopped mysql:8.0.27
```
## 备注
* 请事先在容器中安装zip命令(apt-get update && apt-get install zip)
* 此脚本为docker容器从数据库方案的备份设计
* 容器外执行的备份命令: sudo docker exec mysql_slave bash -c "cd /home/data && ./mysql_docker_backup.sh"
* 同一个binlog文件, 只能使用mysqlbinlog还原一次。若需要重新还原binlog, 需要重建数据库或容器
* 每天一次全量备份, 每4小时一次增量备份, 删除30天前的备份
* 按时间还原增量备份的binlog文件, 命令如: mysqlbinlog mysql-bin.000001 | mysql -uroot -p
## 主数据库增加配置
```
# 设置同步的binary log二进制日志文件名前缀，默认为binlog
log-bin=mysql-bin
# 服务器唯一id，默认为1  主数据库和从数据库的server_id不能重复
server_id=1
# 主从复制的格式（mixed,statement,row，默认格式是statement。建议是设置为row，主从复制时数据更加能够统一）
binlog_format=row
binlog-ignore-db=sys,mysql,information_schema,performance_schema

### 可选配置
# 需要主从复制的数据库
binlog-do-db=test
# 复制过滤：也就是指定哪个数据库不用同步（mysql库一般不同步）
binlog-ignore-db=mysql
# 为每个session分配的内存，在事务过程中用来存储二进制日志的缓存
binlog_cache_size=1M
# 配置二进制日志自动删除/过期时间，单位秒，默认值为2592000，即30天；8.0.3版本之前使用expire_logs_days，单位天数。默认值为0，表示不自动删除。
binlog_expire_logs_seconds=2592000
# 跳过主从复制中遇到的所有错误或指定类型的错误，避免slave端复制中断，默认OFF关闭，可选值有OFF、all、ddl_exist_errors以及错误码列表。8.0.26版本之前使用slave_skip_errors
# 如：1062错误是指一些主键重复，1032错误是因为主从数据库数据不一致
replica_skip_errors=1062
```
### 主数据库增加slave用户
```
CREATE USER 'slave1'@'%' IDENTIFIED BY '[PASSWORD]';
GRANT REPLICATION SLAVE ON *.* TO 'slave1'@'%';
flush privileges;
show master status;
```
## 从库配置
```
###主从数据库配置核心部分
# 设置同步的binary log二进制日志文件名前缀，默认是binlog
log-bin=mysql-bin
# 服务器唯一ID  主数据库和从数据库的server_id不能重复
server_id=2
# 主从复制的格式（mixed,statement,row，默认格式是statement。建议是设置为row，主从复制时数据更加能够统一） 
binlog_format=row
# 防止改变数据(只读操作，除了特殊的线程)
read_only=1
binlog-ignore-db=sys,mysql,information_schema,performance_schema

###可选配置
# 需要主从复制的数据库
replicate-do-db=test
# 复制过滤：也就是指定哪个数据库不用同步（mysql库一般不同步）
binlog-ignore-db=mysql
# 为每个session分配的内存，在事务过程中用来存储二进制日志的缓存 
binlog_cache_size=1M
# 配置二进制日志自动删除/过期时间，单位秒，默认值为2592000，即30天；8.0.3版本之前使用expire_logs_days，单位天数。默认值为0，表示不自动删除。
binlog_expire_logs_seconds=2592000
# 跳过主从复制中遇到的所有错误或指定类型的错误，避免slave端复制中断，默认OFF关闭，可选值有OFF、all、ddl_exist_errors以及错误码列表。8.0.26版本之前使用slave_skip_errors
# 如：1062错误是指一些主键重复，1032错误是因为主从数据库数据不一致
replica_skip_errors=1062
# relay_log配置中继日志，默认采用 主机名-relay-bin 的方式保存日志文件 
relay_log=replicas-mysql-relay-bin  
# log_replica_updates表示slave是否将复制事件写进自己的二进制日志，默认值ON开启；8.0.26版本之前使用log_slave_updates
log_replica_updates=ON
```
### MASTER_LOG_FILE及MASTER_LOG_POS的值请参考主库中执行show master status;后的结果
```
change master to MASTER_HOST='172.20.0.1',MASTER_PORT=3306,MASTER_USER='slave1',MASTER_PASSWORD='[PASSWORD]',MASTER_LOG_FILE='mysql-bin.000001',MASTER_LOG_POS=1;
```
### 在从库中启动slave
```
start slave;
```
### 查看从库slave状态
```
show slave status;
```
### 其他
```
# 停止主从复制
stop slave;
# 清空之前的主从复制配置信息
reset slave;
```

### 主从配置中增加以下配置
```
# 开启gtid模式
gtid_mode=on
# 强制gtid一致性，开启后对于特定create table不被支持
enforce_gtid_consistency=on
```
### 从库的SQL变为
```
change master to MASTER_HOST='172.20.0.1',MASTER_PORT=3306,MASTER_USER='slave1',MASTER_PASSWORD='[PASSWORD]'
# 1 代表采用GTID协议复制, 0 代表采用老的binlog复制
MASTER_AUTO_POSITION=1;
```