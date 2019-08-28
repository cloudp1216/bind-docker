
#### 一、内部DNS系统

    主要针对内部域名"speech.local"提供解析服务。
    软件"bind-9.11.9.tar.gz"从官网"https://www.isc.org"下载，运行为Docker容器服务。


#### 二、制作bind镜像

**1.Dockerfile**

```shell
FROM scratch

ADD centos-7-x86_64-docker.tar.xz /
ADD bind-9.11.9.tar.gz /tmp

COPY set_mirror.sh /usr/local/bin
COPY entrypoint.sh /usr/local/bin
COPY tini_0.18.0-amd64.rpm /tmp

RUN set -x \
        && /bin/cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
        && find /etc/yum.repos.d -name "*.repo" -exec unlink {} \; \
        && set_mirror.sh \
        && yum clean all \
        && yum install -y gcc make file net-tools mariadb mariadb-libs mariadb-devel 2>/dev/null \
        && cd /tmp/bind-9.11.9 \
        && ./configure \
                --prefix=/usr/local/bind \
                --enable-epoll \
                --enable-threads \
                --enable-largefile \
                --disable-ipv6 \
                --with-dlz-mysql=yes \
                --without-python \
                --with-openssl=no \
        && make \
        && make install \
        && cd /tmp/bind-9.11.9/contrib/dlz/modules/mysql \
        && make 2>/dev/null \
        && install dlz_mysql_dynamic.so /usr/local/bind/lib \
        && echo "PATH=/usr/local/bind/sbin:/usr/local/bind/bin:\$PATH" >> /etc/profile \
        && rpm -ivh /tmp/tini_0.18.0-amd64.rpm \
        && source /etc/profile \
        && cd /usr/local/bind/etc \
        && rndc-confgen > rndc.conf \
        && tail -n10 rndc.conf | head -n9 | sed 's/^# //g' > named.conf \
        && rpm -e gcc \
        && yum clean all \
        && rm -fr /tmp/bind* /tmp/tini*

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/entrypoint.sh"]
```

**2.制作bind镜像**

```shell
[root@docker bind]# docker-compose build
Building bind
Step 1/9 : FROM scratch
 ---> 
Step 2/9 : ADD centos-7-x86_64-docker.tar.xz /
 ---> Using cache
 ---> 99a90b4522d9
Step 3/9 : ADD bind-9.11.9.tar.gz /tmp
.....

[root@docker bind]# docker images bind
REPOSITORY          TAG                 IMAGE ID            CREATED             SIZE
bind                20190725            3ec4c7f28439        7 days ago          675MB
```


#### 三、初始化bind数据库

**1.安装mariadb**
```shell
[root@dockert bind]# yum install -y mariadb-server
```

**2.创建bind数据库**
```sql
MariaDB [(none)]> CREATE DATABASE bind DEFAULT CHARACTER SET utf8 COLLATE utf8_general_ci;
```

**3.创建bind用户并授予查询权限**
```sql
MariaDB [(none)]> CREATE USER 'bind'@'%' IDENTIFIED BY 'xxxx';
MariaDB [(none)]> GRANT SELECT ON bind.* TO 'bind'@'%';
```

**4.导入bind库**
```sql
MariaDB [(none)]> use bind
MariaDB [bind]> source bind.sql
```

**5.开启mariadb远程连接权限（根据具体情况选择）**
```sql
MariaDB [(none)]> GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' IDENTIFIED BY 'xxxx';
```

**6.bind.records表结构及默认zone的sql语句如下：**
```sql
-- 创建表结构
CREATE TABLE IF NOT EXISTS `records` (
    `id` int(10) unsigned NOT NULL AUTO_INCREMENT,
    `zone` varchar(255) NOT NULL,
    `ttl` int(11) NOT NULL DEFAULT '86400',
    `type` varchar(255) NOT NULL,
    `host` varchar(255) NOT NULL DEFAULT '@',
    `mx_priority` int(11) DEFAULT NULL,
    `data` text,
    `primary_ns` varchar(255) DEFAULT NULL,
    `resp_contact` varchar(255) DEFAULT NULL,
    `serial` bigint(20) DEFAULT NULL,
    `refresh` int(11) DEFAULT NULL,
    `retry` int(11) DEFAULT NULL,
    `expire` int(11) DEFAULT NULL,
    `minimum` int(11) DEFAULT NULL,
    PRIMARY KEY (`id`),
    KEY `type` (`type`),
    KEY `host` (`host`),
    KEY `zone` (`zone`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;


-- 添加Zone和NS
INSERT INTO `records` (`zone`, `ttl`, `type`, `host`, `mx_priority`, `data`, `primary_ns`, `resp_contact`, `serial`, `refresh`, `retry`, `expire`, `minimum`) VALUES
('speech.local', 86400, 'SOA', '@', NULL, NULL, 'ns1.speech.local.', 'speech.local.', 2019072501, 10800, 7200, 604800, 86400),
('speech.local', 86400, 'NS', '@', NULL, 'ns1.speech.local.', NULL, NULL, NULL, NULL, NULL, NULL, NULL),
('speech.local', 86400, 'NS', '@', NULL, 'ns2.speech.local.', NULL, NULL, NULL, NULL, NULL, NULL, NULL);


-- 添加A记录
INSERT INTO `records` (`zone`, `ttl`, `type`, `host`, `data`) VALUES
('speech.local', 86400, 'A', 'ns1', '10.0.0.230');


-- 添加CNAME
INSERT INTO `records` (`zone`, `ttl`, `type`, `host`, `data`) VALUES
('speech.local', 86400, 'CNAME', 'ns2', 'ns1.speech.local.');
```


#### 四、启动bind服务

**1.docker-compose文件如下：**
```yaml
version: "3"
services:
    bind:
        build:
            context: ./
            dockerfile: Dockerfile
        image: bind:20190725                    # 镜像名称
        environment:
            DB_HOST: 172.17.0.1                 # 数据库地址，默认为docker0桥
            DB_PORT: 3306                       # 数据库端口
            DB_NAME: bind                       # 数据库
            DB_USER: bind                       # 数据库账号（此账号只有查询权限）
            DB_PASS: xxxx                       # 数据库密码
            DNS1: 114.114.114.114               # DNS转发1
            DNS2: 8.8.8.8                       # DNS转发2
        ports: 
          - 53:53/udp                           # 对外开放端口
```

**2.entrypoint脚本如下：**
```bash
#!/bin/bash
#


source /etc/profile

# named configure file.
nsconf="/usr/local/bind/etc/named.conf"


function init_config() {
# db info.
DB_HOST=${DB_HOST:="127.0.0.1"}
DB_PORT=${DB_PORT:="3306"}
DB_NAME=${DB_NAME:="bind"}
DB_USER=${DB_USER:="bind"}
DB_PASS=${DB_PASS:="bind"}

# dns forward.
DNS1=${DNS1:="114.114.114.114"}
DNS2=${DNS2:="8.8.8.8"}

if [ `cat $nsconf | grep 'dlz_mysql_dynamic.so' -c` -eq 0 ]; then
cat >> $nsconf <<EOF

options {
        listen-on port 53 { any; };
        directory "/usr/local/bind/var";
        pid-file "named.pid";
        allow-query { any; };
        recursion yes;
        forwarders { $DNS1; $DNS2; };
};

dlz "mysql" {
    database "dlopen ../lib/dlz_mysql_dynamic.so

           { host=$DB_HOST port=$DB_PORT dbname=$DB_NAME user=$DB_USER pass=$DB_PASS threads=2 }

           { SELECT zone 
                FROM records 
                WHERE zone = '\$zone\$' }
           { SELECT ttl, type, mx_priority, IF(type = 'TXT', CONCAT('\"',data,'\"'), data) AS data 
                FROM records 
                WHERE zone = '\$zone\$' AND host = '\$record\$' AND type <> 'SOA' AND type <> 'NS' }
           { SELECT ttl, type, data, primary_ns, resp_contact, serial, refresh, retry, expire, minimum 
                FROM records 
                WHERE zone = '\$zone\$' AND (type = 'SOA' OR type='NS') }
           { SELECT ttl, type, host, mx_priority, IF(type = 'TXT', CONCAT('\"',data,'\"'), data) AS data, resp_contact, serial, refresh, retry, expire, minimum 
                FROM records 
                WHERE zone = '\$zone\$' AND type <> 'SOA' AND type <> 'NS' }";
};
EOF
fi
}

init_config

exec /usr/local/bind/sbin/named -g
```

**3.启动bind容器：**
```shell
[root@docker bind]# docker-compose up -d
Creating network "bind_default" with the default driver
Creating bind_bind_1 ... done
```

**4.停止bind容器：**
```shell
[root@docker bind]# docker-compose down
Stopping bind_bind_1 ... done
Removing bind_bind_1 ... done
Removing network bind_default
```

**5.查看日志：**
```shell
[root@docker bind]# docker-compose logs -f
```


#### 五、添加DNS解析记录

在mariadb开启远程连接的情况下，使用"Navicat for MySQL"连接数据库添加A记录即可（或者使用INSERT语句添加）。


#### 六、使用dig命令解析

**1.使用dig解析域名如下：**
```shell
[root@localhost bind]# dig @10.0.0.230 mirror.speech.local

; <<>> DiG 9.11.9 <<>> @10.0.0.230 mirror.speech.local
; (1 server found)
;; global options: +cmd
;; Got answer:
;; WARNING: .local is reserved for Multicast DNS
;; You are currently testing what happens when an mDNS query is leaked to DNS
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 4904
;; flags: qr aa rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 2, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 4096
; COOKIE: 0c41ededa45013fc6c9108255d429f8e3217fd63673c5c77 (good)
;; QUESTION SECTION:
;mirror.speech.local.       IN  A

;; ANSWER SECTION:
mirror.speech.local.    86400   IN  A   10.0.0.11

;; AUTHORITY SECTION:
speech.local.       86400   IN  NS  ns2.speech.local.
speech.local.       86400   IN  NS  ns1.speech.local.

;; Query time: 5 msec
;; SERVER: 10.0.0.230#53(10.0.0.230)
;; WHEN: Thu Aug 01 00:21:25 EDT 2019
;; MSG SIZE  rcvd: 128
```


#### 七、数据库调优

```shell
[root@docker ~]# vi /etc/my.cnf                   # 在[mysqld]中添加

skip-name-resolve
table_open_cache=256
read_buffer_size=2M
query_cache_type=1
query_cache_size=128M
thread_cache_size=16
innodb_buffer_pool_size=256M
innodb_read_io_threads=8
innodb_write_io_threads=8

```

#### 八、使用DNS多实例

**1.修改docker-compose.yml文件增加容器个数**
```yaml
version: "3"
services:
    bind_11053:
        build:
            context: ./
            dockerfile: Dockerfile
        image: bind:20190725
        environment:
            DB_HOST: 172.17.0.1
            DB_PORT: 3306
            DB_NAME: bind
            DB_USER: bind
            DB_PASS: bind
            DNS1: 114.114.114.114
            DNS2: 8.8.8.8
        ports:
          - 11053:53/udp

    bind_12053:
        build:
            context: ./
            dockerfile: Dockerfile
        image: bind:20190725
        environment:
            DB_HOST: 172.17.0.1
            DB_PORT: 3306
            DB_NAME: bind
            DB_USER: bind
            DB_PASS: bind
            DNS1: 114.114.114.114
            DNS2: 8.8.8.8
        ports:
          - 12053:53/udp

    bind_13053:
        build:
            context: ./
            dockerfile: Dockerfile
        image: bind:20190725
        environment:
            DB_HOST: 172.17.0.1
            DB_PORT: 3306
            DB_NAME: bind
            DB_USER: bind
            DB_PASS: bind
            DNS1: 114.114.114.114
            DNS2: 8.8.8.8
        ports:
          - 13053:53/udp
```

```shell
[root@docker bind]# docker-compose up -d
[root@docker bind]# docker-compose ps
      Name                     Command               State           Ports        
----------------------------------------------------------------------------------
bind_bind_11053_1   /usr/bin/tini -- /usr/loca ...   Up      0.0.0.0:11053->53/udp
bind_bind_12053_1   /usr/bin/tini -- /usr/loca ...   Up      0.0.0.0:12053->53/udp
bind_bind_13053_1   /usr/bin/tini -- /usr/loca ...   Up      0.0.0.0:13053->53/udp
```

**2.编译安装nginx**
```shell
[root@docker ~]# tar zxf nginx-1.16.0.tar.gz
[root@docker ~]# cd nginx-1.16.0
[root@docker nginx-1.16.0]# ./configure --prefix=/usr/local/nginx --with-stream
[root@docker nginx-1.16.0]# make
[root@docker nginx-1.16.0]# make install
```

**3.修改nginx配置文件**
```shell
[root@docker ~]# vi /usr/local/nginx/conf/nginx.conf

user  nobody;
worker_processes  8;
worker_rlimit_nofile 65535;

error_log logs/error.log error;

events {
    use epoll;
    worker_connections  65535;
}

stream {
    upstream dns {
        server 10.0.0.230:11053 weight=10;
        server 10.0.0.230:12053 weight=10;
        server 10.0.0.230:13053 weight=10;
    }

    server {
        listen 53 udp;
        proxy_pass dns;
        proxy_timeout 5s;
        proxy_responses 1;
    }
}
```

**4.启动nginx代理**
```shell
[root@docker ~]# /usr/local/nginx/sbin/nginx
```


