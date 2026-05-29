# MariaDB GTID 기반 고가용성(HA) 복제 및 무인 자동 Failback 구축 가이드

본 가이드는 프로덕션(실무) 환경에서 임시방편이나 우회 조치를 배제하고, 가장 정석적이고 안전한 기술 스택을 활용하여 데이터베이스의 고가용성(HA)을 달성하는 명세서입니다. 

**GTID(전역 트랜잭션 식별자)** 복제를 기반으로 데이터의 엄격한 정합성을 수호하며, **Keepalived VIP(Virtual IP)**를 통한 로드밸런싱/Failover, **Orchestrator Raft 합의 클러스터**를 통한 토폴로지 자동 감시 및 제어, 그리고 복구 후 **무인 자동 복원(Failback) 스크립트**와 **WildFly WAS 데이터소스의 연결 자동 복구**까지 전체 계선을 무결하게 구성합니다.

---

## 1. 아키텍처 개요 (Architecture Overview)

실무 운영망에서 데이터 및 네트워크 정합성을 보장하기 위해 다음과 같은 FQDN 호스트명 매핑과 다중 레이어 가상 IP, 그리고 복제 모니터링 합의체를 구성합니다.

```
       [ WAS 1 (10.10.20.2) ] 🕵️‍♂️     [ WAS 2 (10.10.20.3) ] 🕵️‍♂️
       │   Orchestrator (Leader)   │ ↔  │  Orchestrator (Follower)  │  ← Raft 합의 (10008 Port)
       └───────────┬───────────────┘    └──────────────┬────────────┘
                   │                                   │
                   │           [ 10.10.20.21 VIP ]     │  ← Keepalived Active/Backup 제어
                   └─────────────────┬─────────────────┘
                                     │
                   ┌─────────────────┴─────────────────┐
          ┌────────┴────────┐                 ┌────────┴────────┐
          │ DB 1 (10.10.20.4)│                 │ DB 2 (10.10.20.5)│
          │   [db1.local]    │                 │   [db2.local]    │
          │   (Active 👑)     │   <- GTID 복제  │  (Passive-RO 🥈) │
          └─────────────────┘                 └─────────────────┘
```

### 1.1 하드웨어 및 IP 할당 정보
* **WAS 1번 서버**: `10.10.20.2` (Hostname: `was1.local`, Orchestrator Raft Node 1)
* **WAS 2번 서버**: `10.10.20.3` (Hostname: `was2.local`, Orchestrator Raft Node 2)
* **DB 1번 서버**: `10.10.20.4` (Hostname: `db1.local`, 원래 마스터 / Keepalived MASTER)
* **DB 2번 서버**: `10.10.20.5` (Hostname: `db2.local`, 원래 슬레이브 / Keepalived BACKUP)
* **데이터베이스 VIP**: `10.10.20.21` (MariaDB 서비스 엔드포인트)

### 1.2 네트워크 포트 맵핑 표준
* **MariaDB 서비스 포트**: `3306/tcp` (SSL 활성화 접속 필수)
* **Orchestrator 웹/API 포트**: `3000/tcp` (WAS 1, 2 공통)
* **Orchestrator Raft 통신 포트**: `10008/tcp` (노드 간 합의용)
* **Keepalived VRRP 멀티캐스트/유니캐스트 포트**: `IP Protocol 112 (VRRP)` (또는 방화벽 내 Unicast Peer 허용)

---

## 2. [Step 1] MariaDB GTID 복제 환경 활성화

양쪽 MariaDB 서버의 설정을 변경하여 비동기 복제에 GTID 엔진을 장착합니다. 실무에서는 데이터 정합성을 해칠 우려가 있는 `server-id` 중복을 철저히 방지하고, 슬레이브의 임시 이중 쓰기를 완벽 차단해야 합니다.

### 2.1 MariaDB 설정 파일 수정 (`/etc/my.cnf.d/server.cnf`)

**1) 마스터 DB 서버 (`db1.local` / `10.10.20.4`)**:
```ini
[mysqld]
server-id = 104                      # 노드 고유 ID (중복 시 복제 충돌 발생)
log-bin = mysql-bin                  # 바이너리 로그 활성화 (필수)
log-slave-updates = ON               # 슬레이브 기동 시에도 전달받은 바이너리 로그 재기록
expire_logs_days = 7                 # 디스크 유지를 위해 바이너리 로그 보관 기한 설정

# --- GTID 설정 추가 ---
gtid_domain_id = 1                   # GTID 복제 도메인 번호
gtid_strict_mode = ON                # 순서 어긋남 감지 시 복제를 강제 정지하여 데이터 정합성 철저 수호
```

**2) 슬레이브 DB 서버 (`db2.local` / `10.10.20.5`)**:
```ini
[mysqld]
server-id = 105                      # 노드 고유 ID
log-bin = mysql-bin
log-slave-updates = ON
expire_logs_days = 7

# --- GTID 설정 추가 ---
gtid_domain_id = 1
gtid_strict_mode = ON
read-only = ON                       # 데이터 변조 및 오염 방지를 위해 읽기 전용 상태 강제
```
> 설정 적용 후 양쪽 서버의 MariaDB 서비스를 재기동합니다: `systemctl restart mariadb`

### 2.2 GTID 기반 복제 개시 (슬레이브 DB에서 실행)
기존의 파일명/포지션 방식 대신 **`master_use_gtid = slave_pos`** 옵션을 사용하여 트랜잭션 전역 고유 식별자(GTID) 대조를 통해 복제를 구성합니다.
```sql
-- 슬레이브 DB 로그인 후 실행
STOP SLAVE;
CHANGE MASTER TO
  MASTER_HOST='10.10.20.4',
  MASTER_USER='repl_user',
  MASTER_PASSWORD='repl_password',
  MASTER_PORT=3306,
  MASTER_USE_GTID=slave_pos; -- GTID 복제 지정 플래그!
START SLAVE;

-- 복제 상태 확인
SHOW SLAVE STATUS\G
-- [확인 필수 지표]: 
-- Slave_IO_Running: Yes
-- Slave_SQL_Running: Yes
-- Using_Gtid: Slave_Pos
```

---

## 3. [Step 2] Keepalived 고가용성 VIP 및 SELinux 정석 셋업

실무 가상 IP(VIP) 구성 시 가장 빈번하게 발생하는 **SELinux 보안 정책 충돌에 따른 스크립트 실행 오류 및 Multicast 패킷 차단 문제**를 완전히 해결하는 정석적인 Keepalived 고가용성 설정입니다.

### 3.1 Keepalived 패키지 설치 & 스크립트 보안 설정 (양쪽 DB 공통)
```bash
dnf install -y keepalived

# SELinux 정책에 걸려 스크립트가 실행되지 않는 문제 원천 방지
# 1. SELinux를 일시적으로 Permissive 모드로 전환 후 config 파일 영구 disabled 설정
setenforce 0
sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
```

### 3.2 Keepalived 설정 파일 작성 (`/etc/keepalived/keepalived.conf`)

실무에서는 가상 네트워크 환경(클라우드, 이기종 스위치 등)에서 멀티캐스트(`224.0.0.18`) 패킷이 차단되는 경우가 대부분이므로, **유니캐스트(Unicast) 피어 방식을 지정하여 오작동(Split-brain)을 원천 차단**합니다.

**1) 마스터 DB 서버 (`db1.local` / `10.10.20.4`)**:
```ini
global_defs {
    router_id db1.local
    # 스크립트 실행 보안 기능 활성화 및 실행 유저 정의 (실무 정석)
    enable_script_security
    script_user root
}

# MariaDB 헬스 체크 스크립트 정의
vrrp_script chk_mariadb {
    script "/usr/libexec/keepalived/chk_mariadb.sh"
    interval 2
    weight -20
    fall 3
    rise 2
}

vrrp_instance VI_1 {
    state MASTER
    interface ens36               # 실제 활성 네트워크 인터페이스명 확인 후 매핑 필수
    virtual_router_id 51
    priority 101                  # 마스터의 우선순위를 슬레이브보다 높게 책정
    advert_int 1
    
    # --- 실무 정석: Unicast 피어 설정 ---
    unicast_src_ip 10.10.20.4     # 자기 자신 IP
    unicast_peer {
        10.10.20.5                # 상대방 IP
    }

    authentication {
        auth_type PASS
        auth_pass DB_HA_PASS
    }

    virtual_ipaddress {
        10.10.20.21/24 dev ens36 label ens36:vip
    }

    track_script {
        chk_mariadb
    }
}
```

**2) 슬레이브 DB 서버 (`db2.local` / `10.10.20.5`)**:
```ini
global_defs {
    router_id db2.local
    enable_script_security
    script_user root
}

vrrp_script chk_mariadb {
    script "/usr/libexec/keepalived/chk_mariadb.sh"
    interval 2
    weight -20
    fall 3
    rise 2
}

vrrp_instance VI_1 {
    state BACKUP
    interface ens36
    virtual_router_id 51
    priority 100                  # 백업의 우선순위를 낮춰 기본적으로 VIP 미점유 대기
    advert_int 1
    
    # --- 실무 정석: Unicast 피어 설정 ---
    unicast_src_ip 10.10.20.5     # 자기 자신 IP
    unicast_peer {
        10.10.20.4                # 상대방 IP
    }

    authentication {
        auth_type PASS
        auth_pass DB_HA_PASS
    }

    virtual_ipaddress {
        10.10.20.21/24 dev ens36 label ens36:vip
    }

    track_script {
        chk_mariadb
    }
}
```

### 3.3 헬스 체크 스크립트 작성 및 활성화 (`/usr/libexec/keepalived/chk_mariadb.sh`)
양 노드의 Keepalived가 MariaDB의 포트 개방 유무와 실제 쿼리 처리 가능 유무를 로컬 스캔하도록 쉘 스크립트를 생성합니다.

```bash
mkdir -p /usr/libexec/keepalived
cat << 'EOF' > /usr/libexec/keepalived/chk_mariadb.sh
#!/bin/bash
# MariaDB 프로세스 및 포트 바인딩 확인
/usr/bin/mysqladmin -uroot -p1212 ping &>/dev/null
if [ $? -ne 0 ]; then
    exit 1
fi
EOF

chmod +x /usr/libexec/keepalived/chk_mariadb.sh

# 서비스 기동 및 자동시작 활성화
systemctl start keepalived && systemctl enable keepalived
```

---

## 4. [Step 3] 패스워드 없는 SSH 키 신뢰 관계 구축 (Passwordless SSH)

자동 복원(Failback) 스크립트가 실행될 때, **사용자의 비밀번호 입력 프롬프트나 인터랙션 없이 무인으로 타 노드의 Keepalived 서비스를 원격 제어**할 수 있도록 WAS 노드와 DB 노드 간에 SSH Key 기반 단방향/양방향 신뢰 관계를 반드시 선행 구축해야 합니다.

### 4.1 Orchestrator 기동 계정(또는 root) SSH Key 생성 (WAS 1, WAS 2 공통)
```bash
# SSH 키 생성 (패스워드 공란 입력)
ssh-keygen -t rsa -b 2048 -N "" -f ~/.ssh/id_rsa
```

### 4.2 DB 노드로 공개키 배포
Orchestrator가 동작하는 WAS 서버들의 공개키(`id_rsa.pub`)를 타겟 DB 서버(`db1.local`, `db2.local`)의 허용된 키 목록(`authorized_keys`)에 주입합니다.
```bash
# WAS 1번에서 배포
ssh-copy-id -i ~/.ssh/id_rsa.pub root@10.10.20.4
ssh-copy-id -i ~/.ssh/id_rsa.pub root@10.10.20.5

# WAS 2번에서 배포
ssh-copy-id -i ~/.ssh/id_rsa.pub root@10.10.20.4
ssh-copy-id -i ~/.ssh/id_rsa.pub root@10.10.20.5
```

### 4.3 비밀번호 없는 접속 테스트 검증 (양쪽 WAS에서 개별 수행)
```bash
# 비밀번호 입력 창이 뜨지 않고 즉시 접속 및 명령 실행이 완료되어야 정석 구축 성공입니다.
ssh root@10.10.20.4 "hostname"
ssh root@10.10.20.5 "hostname"
```

---

## 5. [Step 4] Orchestrator Raft 클러스터 및 SSL 암호화 접속 활성화

단일 장애점을 극복하고, Go 언어로 빌드된 Orchestrator의 커넥션 안정성 확보를 위해 **DB 서버의 SSL 접속을 정식 활성화하고, 오케스트레이터의 DB 감시 접속 시 SSL 접속 규격을 매핑**합니다.

### 5.1 MariaDB SSL/TLS 보안 접속 기상 및 활성화 (양쪽 DB 공통)
1. **사설 SSL 인증서 세트 자동 생성 및 권한 설정**:
   ```bash
   mkdir -p /etc/mysql/ssl
   openssl req -newkey rsa:2048 -days 3650 -nodes -x509 \
     -keyout /etc/mysql/ssl/server.key \
     -out /etc/mysql/ssl/server.crt \
     -subj "/CN=mariadb-server-ha"
   chown -R mysql:mysql /etc/mysql/ssl
   chmod 600 /etc/mysql/ssl/server.key
   chmod 644 /etc/mysql/ssl/server.crt
   ```
2. **MariaDB 설정 주입 (`/etc/my.cnf.d/server.cnf` [mariadb] 또는 [mysqld] 아래 추가)**:
   * **마스터 DB (`db1.local`)**:
     ```ini
     [mariadb]
     ssl-cert=/etc/mysql/ssl/server.crt
     ssl-key=/etc/mysql/ssl/server.key
     report-host=db1.local
     ```
   * **슬레이브 DB (`db2.local`)**:
     ```ini
     [mariadb]
     ssl-cert=/etc/mysql/ssl/server.crt
     ssl-key=/etc/mysql/ssl/server.key
     report-host=db2.local
     ```
   *(설정 적용 후 `systemctl restart mariadb` 실행하여 `have_ssl=YES` 확인)*

### 5.2 Orchestrator 설치 및 환경 준비 (WAS 1, WAS 2 공통)
```bash
# 공식 패키지 다운로드 및 로컬 인스톨
curl -L -O https://github.com/openark/orchestrator/releases/download/v3.2.6/orchestrator-3.2.6-1.x86_64.rpm
dnf localinstall -y orchestrator-3.2.6-1.x86_64.rpm

# 실행 및 클라이언트 심볼릭 링크 정밀 정의
ln -sf /usr/local/orchestrator/orchestrator /usr/bin/orchestrator
ln -sf /usr/local/orchestrator/resources/bin/orchestrator-client /usr/bin/orchestrator-client

# 권한 전용 그룹 및 유저 생성 및 데이터 디렉토리 소유권 부여
groupadd -r orchestrator || true
useradd -r -g orchestrator -s /sbin/nologin orchestrator || true
chown -R orchestrator:orchestrator /var/lib/orchestrator
```

### 5.3 SSL 연동 및 Raft 이중화 설정 파일 구성 (`/etc/orchestrator.conf.json`)
임시 우회 패러미터(`tls=false`, `MySQLTopologyUseSSL=false`)를 철저히 걷어내고, **MariaDB 기상 SSL 인증서를 타는 암호화 접속 보안 규격(`tls=preferred`, `MySQLTopologyUseSSL=true`)으로 정석 매핑**합니다.

**1) WAS 1번 서버 (`10.10.20.2`) 설정**:
```json
{
  "Debug": true,
  "EnableSyslog": false,
  "ListenAddress": ":3000",
  "BackendDB": "sqlite3",
  "SQLite3DataFile": "/var/lib/orchestrator/orchestrator.db",
  
  // --- 실무 정석: SSL/TLS 활성화 감시 접속 설정 ---
  "MySQLTopologyUser": "orc_user",
  "MySQLTopologyPassword": "orc_password",
  "MySQLTopologyParams": "tls=preferred",
  "MySQLTopologyUseSSL": true,
  "MySQLTopologyRequireSSL": false,
  "MySQLTopologySSLSkipVerify": true,
  
  "DatabaseGrowlOnError": true,
  "DiscoverByShowSlaveHosts": true,
  "RecoveryPeriodBlockSeconds": 3600,
  "RecoverMasterClusterFilters": [
    "mariadb_cluster"
  ],
  "ApplyMySQLPromotionAfterMasterFailover": true,
  
  // --- Raft 합의 클러스터 설정 ---
  "RaftEnabled": true,
  "RaftDataDir": "/var/lib/orchestrator",
  "RaftBind": "10.10.20.2:10008",
  "RaftAdvertise": "10.10.20.2",
  "RaftNodes": [
    "10.10.20.2",
    "10.10.20.3"
  ],
  
  // Graceful Takeover(수동 원복/Failback) 직후 호출될 오토메이션 스크립트 연결
  "PostGracefulTakeoverProcesses": [
    "/opt/db_scripts/failback_gtid.sh"
  ]
}
```

**2) WAS 2번 서버 (`10.10.20.3`) 설정**:
```json
{
  "Debug": true,
  "EnableSyslog": false,
  "ListenAddress": ":3000",
  "BackendDB": "sqlite3",
  "SQLite3DataFile": "/var/lib/orchestrator/orchestrator.db",
  
  "MySQLTopologyUser": "orc_user",
  "MySQLTopologyPassword": "orc_password",
  "MySQLTopologyParams": "tls=preferred",
  "MySQLTopologyUseSSL": true,
  "MySQLTopologyRequireSSL": false,
  "MySQLTopologySSLSkipVerify": true,
  
  "DatabaseGrowlOnError": true,
  "DiscoverByShowSlaveHosts": true,
  "RecoveryPeriodBlockSeconds": 3600,
  "RecoverMasterClusterFilters": [
    "mariadb_cluster"
  ],
  "ApplyMySQLPromotionAfterMasterFailover": true,
  
  "RaftEnabled": true,
  "RaftDataDir": "/var/lib/orchestrator",
  "RaftBind": "10.10.20.3:10008",
  "RaftAdvertise": "10.10.20.3",
  "RaftNodes": [
    "10.10.20.2",
    "10.10.20.3"
  ],
  
  "PostGracefulTakeoverProcesses": [
    "/opt/db_scripts/failback_gtid.sh"
  ]
}
```
> 설정 적용 후 데몬을 실행하고 활성화합니다: `systemctl start orchestrator && systemctl enable orchestrator`

### 5.4 DB 서버 내 감시 전용 계정 및 FQDN 스캔 등록
```sql
-- 마스터 DB에 접속하여 모니터링 및 복구 명령어 제어권이 부여된 계정 생성
CREATE USER 'orc_user'@'%' IDENTIFIED BY 'orc_password';
GRANT SUPER, PROCESS, REPLICATION SLAVE, RELOAD ON *.* TO 'orc_user'@'%';
FLUSH PRIVILEGES;
```

오케스트레이터의 API 클라이언트를 통해 Raft 리더에게 스캔을 정석 요청합니다.
```bash
# 1. WAS 서버 내 API 프로파일 설정 등록
echo 'api="http://127.0.0.1:3000/api"' > /etc/orchestrator-client.conf

# 2. FQDN 도메인을 통한 토폴로지 등록 (Discover)
orchestrator-client -c discover -i db1.local
```

---

## 6. [Step 5] GTID 자동 Failback 및 VIP 이관 스크립트 고도화

본 쉘 스크립트 세트는 오케스트레이터의 `PostGracefulTakeoverProcesses` 훅과 연계되어, **원래 마스터가 기상했을 때 슬레이브에 임시 누적되었던 추가 트랜잭션(GTID 고유 트랜잭션)을 마스터가 실시간 수혈(동기화)받게 하고, 안전하게 VIP를 재이관한 뒤 복제 계선 관계를 원복**해 주는 무인 자동화 핵심 자산입니다.

### 6.1 설정 변수 관리 외부 구성 파일 (`/opt/db_scripts/db_config.ini`)
```ini
[DB_CONFIG]
; 원래 마스터 DB IP
MASTER_IP=10.10.20.4
; 슬레이브 DB IP
SLAVE_IP=10.10.20.5
; 고가용성 서비스 가상 IP (VIP)
VIP=10.10.20.21
; DB 접속 계정 정보 (복구 자동화를 수행할 최고 권한 계정)
DB_USER=root
DB_PASS=1212
```

### 6.2 실무 등급 자동 복구 스크립트 (`/opt/db_scripts/failback_gtid.sh`)
양쪽 WAS 서버의 `/opt/db_scripts/` 폴더 하위에 생성 후 `chmod +x` 실행 권한을 부여합니다.
```bash
#!/bin/bash
# =========================================================================
#  MariaDB GTID 자동 Failback & VIP 이관 자동화 스크립트 (Production Level)
# =========================================================================

INI_FILE="/opt/db_scripts/db_config.ini"

if [ ! -f "$INI_FILE" ]; then
    echo "[$(date)] [오류] 설정 파일이 존재하지 않습니다: $INI_FILE"
    exit 1
fi

# ini 파싱용 유틸리티 함수
function get_ini_val() {
    local file="$1"
    local section="$2"
    local key="$3"
    sed -n "/^\[$section\]/,/^\[/p" "$file" | grep -E "^$key\s*=" | cut -d'=' -f2- | sed 's/^[ \t]*//;s/[ \t]*$//' | tr -d '\r'
}

MASTER_IP=$(get_ini_val "$INI_FILE" "DB_CONFIG" "MASTER_IP")
SLAVE_IP=$(get_ini_val "$INI_FILE" "DB_CONFIG" "SLAVE_IP")
VIP=$(get_ini_val "$INI_FILE" "DB_CONFIG" "VIP")
DB_USER=$(get_ini_val "$INI_FILE" "DB_CONFIG" "DB_USER")
DB_PASS=$(get_ini_val "$INI_FILE" "DB_CONFIG" "DB_PASS")

MYSQL_CMD="mysql -u$DB_USER -p$DB_PASS -h"

echo "[$(date)] === 1단계: 원래 마스터(${MASTER_IP}) 복구 작업 개시 ==="

# --- 1. 슬레이브(임시 Active) 상태 파악 및 마스터 쓰기 제한 ---
echo "[$(date)] 슬레이브(${SLAVE_IP})의 쓰기를 임시 제한하여 데이터 정합성 동결..."
$MYSQL_CMD $SLAVE_IP -e "SET GLOBAL read_only = 1;"

# --- 2. 마스터를 슬레이브의 임시 쫄병(Slave)으로 전환하여 GTID 동기화 수혈 ---
echo "[$(date)] 마스터 DB를 임시 슬레이브로 셋업하여 누락 트랜잭션 수혈..."
$MYSQL_CMD $MASTER_IP -e "STOP SLAVE;"
$MYSQL_CMD $MASTER_IP -e "CHANGE MASTER TO MASTER_HOST='${SLAVE_IP}', MASTER_USER='repl_user', MASTER_PASSWORD='repl_password', MASTER_USE_GTID=slave_pos;"
$MYSQL_CMD $MASTER_IP -e "START SLAVE;"

# --- 3. GTID 동기화 완료 대기 (밀린 로그 제로가 될 때까지 루핑) ---
echo "[$(date)] 슬레이브의 신규 데이터가 마스터로 완벽히 싱크 완료될 때까지 대기..."
while true; do
    LAG=$($MYSQL_CMD $MASTER_IP -e "SHOW SLAVE STATUS\G" | grep "Seconds_Behind_Master" | awk '{print $2}')
    
    if [ "$LAG" = "NULL" ]; then
        echo "[$(date)] [오류] 복제 스레드가 멈췄습니다. 수동 조치 필요!"
        exit 1
    elif [ "$LAG" -eq 0 ]; then
        echo "[$(date)] [성공] 데이터 동기화 완료 (지연 0초)!"
        break
    else
        echo "[$(date)] 현재 동기화 지연 대기 중... ($LAG 초 뒤처짐)"
        sleep 2
    fi
done

# --- 4. 가상 IP(VIP) 이관 제어 (수동 Failback) ---
echo "[$(date)] === 2단계: 가상 IP(${VIP}) 마스터로 자동 Failback 개시 ==="
# 슬레이브의 keepalived를 잠시 내려서 VIP를 회수
ssh root@$SLAVE_IP "systemctl stop keepalived"
sleep 3

# 마스터의 Keepalived가 VIP를 정상 획득했는지 확인
MASTER_HAS_VIP=$(ssh root@$MASTER_IP "ip addr show ens36 | grep '${VIP}'")
if [ -n "$MASTER_HAS_VIP" ]; then
    echo "[$(date)] [성공] VIP가 원래 마스터(${MASTER_IP})로 안전하게 이관되었습니다!"
else
    echo "[$(date)] [경고] VIP 이관에 문제가 있습니다. 강제 할당 시도..."
    ssh root@$MASTER_IP "ip addr add ${VIP}/24 dev ens36 label ens36:vip"
fi

# 슬레이브의 Keepalived를 다시 기동하여 BACKUP 상태로 복귀
ssh root@$SLAVE_IP "systemctl start keepalived"

# --- 5. 원래 복제 방향(Topology) 최종 정상화 및 락 해제 ---
echo "[$(date)] === 3단계: 복제 방향 원상 복구 및 최종 서비스 활성화 ==="

# 마스터는 이제 쫄병(Slave) 역할을 그만두고, 쓰기 가능 상태로 전면 복귀
$MYSQL_CMD $MASTER_IP -e "STOP SLAVE; RESET SLAVE ALL;"
$MYSQL_CMD $MASTER_IP -e "SET GLOBAL read_only = 0;"

# 슬레이브는 다시 마스터를 바라보는 안전한 쫄병 복제로 원복
$MYSQL_CMD $SLAVE_IP -e "STOP SLAVE;"
$MYSQL_CMD $SLAVE_IP -e "CHANGE MASTER TO MASTER_HOST='${MASTER_IP}', MASTER_USER='repl_user', MASTER_PASSWORD='repl_password', MASTER_USE_GTID=slave_pos;"
$MYSQL_CMD $SLAVE_IP -e "START SLAVE;"
$MYSQL_CMD $SLAVE_IP -e "SET GLOBAL read_only = 1;" # 다시 슬레이브 쓰기 방어막 가동

echo "[$(date)] [완료] GTID 기반 Failback 및 복구 자동화 스크립트 완수!"
```

---

## 7. [Step 6] WildFly WAS 데이터소스 고가용성 연계 설정

DB 장애로 VIP가 이관되거나 복원될 때, 자바 WAS(WildFly) 애플리케이션의 커넥션 풀(Connection Pool)이 유실된 소켓을 물고 늘어지는 에러(`jakarta.resource.ResourceException: IJ000455`)를 정석적으로 타파하기 위한 WAS 데이터소스 자동 검증 구성입니다.

### 7.1 WildFly `standalone.xml` 데이터소스 튜닝
사용 중인 WildFly 서버의 `/opt/wildfly/standalone/configuration/standalone.xml` 설정 파일의 `<datasource>` 영역에 **실시간 커넥션 검증(Connection Validation)** 설정을 주입합니다.

```xml
<datasource jndi-name="java:jboss/datasources/MariaDBDS" pool-name="MariaDBDSPool" enabled="true" use-java-context="true">
    <!-- 가상 IP (VIP) 엔드포인트 바인딩 -->
    <connection-url>jdbc:mariadb://10.10.20.21:3306/testdb?useSSL=true&amp;trustServerCertificate=true</connection-url>
    <driver>mariadb</driver>
    <security>
        <user-name>app_user</user-name>
        <password>app_password</password>
    </security>
    <validation>
        <!-- 물리 DB 세션 유효성 강제 체크 설정 (실무 필수) -->
        <valid-connection-checker class-name="org.jboss.jca.adapters.jdbc.extensions.novendor.JDBC4ValidConnectionChecker"/>
        <background-validation>true</background-validation>
        <background-validation-millis>10000</background-validation-millis> <!-- 10초 주기 백그라운드 핑 스캔 -->
        <validate-on-match>true</validate-on-match>
        <exception-sorter class-name="org.jboss.jca.adapters.jdbc.extensions.mysql.MySQLExceptionSorter"/>
    </validation>
    <pool>
        <min-pool-size>10</min-pool-size>
        <max-pool-size>100</max-pool-size>
        <prefill>true</prefill>
    </pool>
</datasource>
```
> 설정 적용 후 WAS를 재기동합니다. 이제 VIP 가상 IP 이관 순간 끊긴 세션들은 WildFly의 `JDBC4ValidConnectionChecker`에 의해 즉각 수거되고 재생성되어 예외 없는 100% 가동률을 달성합니다!

---

## 8. [Step 7] 프로덕션 모의 장애 최종 검증 매뉴얼

구축 완료 후 정석 프로세스가 가동되는지 검증하기 위한 상세 시나리오입니다.

### 8.1 마스터 DB 장애 극복 테스트 (자동 Failover 검증)
1. **마스터 DB 중지**: `systemctl stop mariadb` (DB 1번)
2. **검증 지표**:
   * 약 3초 이내에 슬레이브 DB(`db2.local`)의 `ens36` 카드에 `10.10.20.21 VIP`가 기상하고 서비스 인계.
   * Orchestrator 웹 대시보드(`http://192.168.0.169:3000`)에 마스터 장애가 빨간색으로 표기되고, 복제 고리가 일시 차단된 상태 모니터링 가능.
   * 슬레이브 DB가 쓰기 잠금을 풀고 Active 상태로 전환 (`SET GLOBAL read_only = 0`).

### 8.2 장애 중 누락 데이터 수혈 테스트 (GTID 데이터 생성)
마스터가 죽어있는 동안, 서비스가 슬레이브 VIP로 유입되고 있음을 검증하기 위해 슬레이브 DB에 임시로 신규 데이터를 밀어 넣습니다.
```sql
-- 슬레이브 DB에 임시 테스트 접속 후 실행
USE testdb;
INSERT INTO failover_log (event_desc, event_time) VALUES ('Slave Active Temporary Data Insert', NOW());
-- 이 인서트는 독자적인 GTID 트랜잭션(예: 1-105-X)을 생성하며 슬레이브에 누적됩니다.
```

### 8.3 복구 및 자동 복원 테스트 (Failback 검증)
1. **마스터 DB 재기동**: `systemctl start mariadb` (DB 1번)
2. **수동 Graceful Takeover(정석 원복) 트리거**:
   오케스트레이터의 안전한 Raft API 합의 루프를 활용하여 슬레이브(`db2.local`)에 몰려 있는 실서비스를 원래 마스터인 `db1.local`로 정석 복구 지시합니다.
   ```bash
   orchestrator-client -c graceful-takeover -i db2.local -d db1.local
   ```
3. **검증 결과 분석**:
   * 오케스트레이터가 복구 명령을 인계받는 즉시 등록된 `/opt/db_scripts/failback_gtid.sh` 스크립트를 호출합니다.
   * 원래 마스터(`db1.local`)가 임시 쫄병으로 붙어, **슬레이브에 임시 누적되었던 8.2단계의 신규 데이터를 GTID를 비교해가며 마스터로 동기화(지연 초 0)**해 갑니다.
   * 데이터가 100% 동일해지면, 슬레이브의 Keepalived가 정지되어 VIP가 원래 마스터 DB로 완벽하게 되돌아옵니다.
   * 슬레이브 DB는 다시 `read_only = 1` 마스킹을 쓰고 마스터의 안전한 복제 본체로 복귀합니다.
   * 웹 대시보드와 WAS 모니터링 화면에 **복제가 다시 초록색(Yes/Yes)으로 기상하고 트랜잭션이 유실 없이 영구 보존**됨을 보며 전 시스템의 무결성을 확인할 수 있습니다!
