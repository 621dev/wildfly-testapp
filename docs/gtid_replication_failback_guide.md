# MariaDB GTID 기반 이중화 구축 및 복구 자동화 가이드

본 가이드는 가상 IP(VIP) 환경 하에서 **GTID (Global Transaction Identifier)** 전역 식별자 기술을 도입하여 복제 정합성을 철저히 지키고, 복제 관리 오픈소스 솔루션인 **Orchestrator**와 연동하여 마스터 재기동 시 슬레이브에 임시로 누적된 트랜잭션을 마스터로 유실 없이 실시간 자동 원복(Failback)시키는 인프라 구축 및 자동화 스크립트 구현 명세서입니다.

---

## 1. 아키텍처 개요 (Architecture Overview)

```
       [ WAS 서버 (10.10.20.2) ]
       ┌────────────────────────┐
       │   Orchestrator 🕵️‍♂️       │  ← 실시간 토폴로지 감시 및 Failback 스크립트 실행
       └───────────┬────────────┘  
                   │ (GTID 동기화 감시)
         ┌─────────┴─────────┐
         │ (10.10.20.21 VIP) │
┌────────┴────────┐ ┌────────┴────────┐
│ DB 1 (10.10.20.4)│ │ DB 2 (10.10.20.5)│
│  [MASTER] 👑    │ │   [SLAVE] 🥈    │
└─────────────────┘ └─────────────────┘
```
* **목표**: 마스터(`10.10.20.4`) 장애 시 슬레이브(`10.10.20.5`)가 VIP를 넘겨받아 임시 Active 상태가 됩니다. 이후 마스터 재기동 시, 슬레이브에만 새로 발생했던 고유 GTID 데이터를 마스터가 유실 없이 안전하게 역복제하여 동기화하고, 다시 마스터로 VIP를 안전하게 원복(Failback)시킵니다.

---

## 2. [Step 1] MariaDB GTID 복제 환경 활성화

양쪽 MariaDB 서버의 설정을 변경하여 비동기 복제에 GTID 엔진을 장착합니다.

### 2.1 MariaDB 설정 파일 수정 (`/etc/my.cnf.d/server.cnf`)

**1) 마스터 DB 서버 (`10.10.20.4`)**:
```ini
[mysqld]
server-id = 104                      # 노드 고유 ID (겹치면 복제 폭사)
log-bin = mysql-bin                  # 바이너리 로그 활성화 (필수)
log-slave-updates = ON               # 슬레이브에서 받은 로그도 바이너리 로그에 재기록
expire_logs_days = 7                 # 바이너리 로그 보관일

# --- GTID 설정 추가 ---
gtid_domain_id = 1                   # GTID 복제 도메인 번호
gtid_strict_mode = ON                # 순서 어긋남 감지 시 복제를 정지하여 데이터 정합성 철저 수호
```

**2) 슬레이브 DB 서버 (`10.10.20.5`)**:
```ini
[mysqld]
server-id = 105                      # 노드 고유 ID
log-bin = mysql-bin
log-slave-updates = ON
expire_logs_days = 7

# --- GTID 설정 추가 ---
gtid_domain_id = 1
gtid_strict_mode = ON
read-only = ON                       # 데이터 오염 방지를 위해 읽기 전용 상태 강제
```
> 설정 적용 후 양쪽 서버의 MariaDB 서비스를 재기동합니다: `systemctl restart mariadb`

### 2.2 GTID 기반 복제 개시 (슬레이브 DB에서 실행)
기존의 파일명/포지션 방식 대신 **`master_use_gtid = slave_pos`** 옵션을 사용하여 깃허브처럼 트랜잭션 주민번호(GTID) 대조를 통해 복제를 맺습니다.
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
-- [확인 지표]: Slave_IO_Running: Yes, Slave_SQL_Running: Yes, Using_Gtid: Slave_Pos
```

---

## 3. [Step 2] 복제 관리 솔루션 (Orchestrator) 연동

GitHub에서 개발하여 사실상 업계 표준으로 자리 잡은 **Orchestrator**를 활용해 복제 토폴로지를 관리합니다. 단 한 대의 WAS에만 기동할 수도 있으나, 모니터링 시스템 자체의 단일 장애점(SPOF)을 제거하기 위해 **두 대의 WAS 서버 모두에 설치하여 Raft 합의 클러스터로 구동**하는 고가용성 구성을 권장합니다.

### 3.1 Orchestrator 설치 (WAS 1, WAS 2 공통 실행)
1. Orchestrator 패키지 설치:
   ```bash
   yum install -y orchestrator
   ```

   ```bash
   # 1. GitHub 공식 저장소에서 CentOS/RHEL용 최신 안정버전(v3.2.6) RPM 파일 다운로드
   curl -L -O https://github.com/openark/orchestrator/releases/download/v3.2.6/orchestrator-3.2.6-1.x86_64.rpm
   # 2. 다운로드한 RPM 파일을 dnf로 로컬 인스톨 (의존성 라이브러리 자동 해결)
   dnf localinstall -y orchestrator-3.2.6-1.x86_64.rpm
   ln -s /usr/local/orchestrator/orchestrator /usr/bin/orchestrator

   # 3. 설정 템플릿 복사 및 SQLite 메타데이터 저장 경로 생성 & 권한 설정
   cp /usr/local/orchestrator/orchestrator-sample.conf.json /etc/orchestrator.conf.json
   mkdir -p /var/lib/orchestrator

   # (선택) 보안 격리용 orchestrator 시스템 계정 생성 후 소유권 변경
   groupadd -r orchestrator || true
   useradd -r -g orchestrator -s /sbin/nologin orchestrator || true
   chown -R orchestrator:orchestrator /var/lib/orchestrator
   ```
2. Raft 클러스터 통신을 위한 포트 (`10008/tcp`) 방화벽 허용 (두 서버 모두 실행):
   ```bash
   firewall-cmd --permanent --add-port=10008/tcp
   firewall-cmd --reload
   ```

### 3.2 Raft 이중화 설정 파일 수정 (`/etc/orchestrator.conf.json`)

> 💡 **설정 팁**: Orchestrator 자체 데이터 저장용 DB가 따로 없는 경우, 두 WAS 간에 Raft로 알아서 동기화되는 **내장 SQLite 백엔드**를 쓰는 것이 이중화 및 유지관리에 가장 좋습니다. 설정 파일(`orchestrator.conf.json`)에 제공되는 Consul, Graphite 등 다른 외부 연동 설정은 기본값(공란) 그대로 냅두셔도 무방합니다.
>
> ⚠️ **중요 (필독)**: 아래 예제 코드들은 독자의 이해를 돕기 위해 **설명 주석(`//`)**을 달아두었습니다. 하지만 **실제 `/etc/orchestrator.conf.json` 파일은 표준 JSON 형식이므로 주석을 지원하지 않습니다.** 실제 설정 파일을 작성하실 때는 `//`로 시작하는 설명 라인은 모두 제외하고 입력하셔야 정상 구동됩니다!

**1) WAS 1번 서버 (`10.10.20.2`) 설정**:
```json
{
  "Debug": true,
  "ListenAddress": ":3000",

  // --- Orchestrator 자체 메타데이터 저장용 백엔드 DB 설정 (내장 SQLite 사용) ---
  "BackendDB": "sqlite",
  "SQLite3DataFile": "/var/lib/orchestrator/orchestrator.db",
  // ------------------------------------------------------------------------

  "MySQLTopologyUser": "orch_user",
  "MySQLTopologyPassword": "orch_password",
  "DatabaseGrowlOnError": true,
  "DiscoverByShowSlaveHosts": true,
  "RecoveryPeriodBlockSeconds": 3600,
  "RecoverMasterClusterFilters": [
    "mariadb_cluster"
  ],
  "ApplyMySQLPromotionAfterMasterFailover": true,
  
  // --- Raft 클러스터링 고가용성 설정 추가 ---
  "RaftEnabled": true,
  "RaftBind": "10.10.20.2:10008",
  "RaftAdvertise": "10.10.20.2",
  "RaftNodes": [
    "10.10.20.2",
    "10.10.20.3"
  ],
  // ------------------------------------------

  // Failover/Failback 감지 시 실행할 커스텀 복구 자동화 스크립트 연결
  "PostGracefulTakeoverProcesses": [
    "/opt/db_scripts/failback_gtid.sh"
  ]
}
```

**2) WAS 2번 서버 (`10.10.20.3`) 설정**:
```json
{
  "Debug": true,
  "ListenAddress": ":3000",

  // --- Orchestrator 자체 메타데이터 저장용 백엔드 DB 설정 (내장 SQLite 사용) ---
  "BackendDB": "sqlite",
  "SQLite3DataFile": "/var/lib/orchestrator/orchestrator.db",
  // ------------------------------------------------------------------------

  "MySQLTopologyUser": "orch_user",
  "MySQLTopologyPassword": "orch_password",
  "DatabaseGrowlOnError": true,
  "DiscoverByShowSlaveHosts": true,
  "RecoveryPeriodBlockSeconds": 3600,
  "RecoverMasterClusterFilters": [
    "mariadb_cluster"
  ],
  "ApplyMySQLPromotionAfterMasterFailover": true,
  
  // --- Raft 클러스터링 고가용성 설정 추가 ---
  "RaftEnabled": true,
  "RaftBind": "10.10.20.3:10008",
  "RaftAdvertise": "10.10.20.3",
  "RaftNodes": [
    "10.10.20.2",
    "10.10.20.3"
  ],
  // ------------------------------------------

  "PostGracefulTakeoverProcesses": [
    "/opt/db_scripts/failback_gtid.sh"
  ]
}
```
> 설정 완료 후 양쪽 WAS 서버에서 서비스를 구동하고 부팅 시 자동 시작되도록 등록합니다: 
> `systemctl start orchestrator && systemctl enable orchestrator`


---

## 4. [Step 3] GTID 기반 무인 자동 Failback 스크립트 구현

본 장애 복구 자동화 스크립트 세트는 **마스터 DB 장애 해제 후 재기동 시**, 슬레이브에 임시로 독자 기동했던 트랜잭션을 마스터로 실시간 수혈(동기화)하고 복제를 원래 방향으로 되돌린 뒤, VIP 이관까지 전면 자동화해 주는 고도화된 스크립트 솔루션입니다.

### 📌 스크립트 배치 대상 서버
* 이 스크립트와 설정 파일은 DB 서버가 아닌, **Orchestrator가 동작하며 복구 이벤트를 직접 실행하는 `WAS 1번 서버 (10.10.20.2)` 및 `WAS 2번 서버 (10.10.20.3)` 두 대의 `/opt/db_scripts/` 경로에 동일하게 배치되어야 합니다.**
* 두 서버 모두에 아래 파일들을 생성하고 실행 권한(`chmod +x`)을 부여해 줍니다.

---

### 4.1 설정 변수 관리용 외부 설정 파일 (`/opt/db_scripts/db_config.ini`)
보안 및 인프라 변경 시 편의성을 높이기 위해 스크립트 내부에서 사용되는 모든 환경 변수들을 별도의 `.ini` 파일로 분리하여 관리합니다.

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

---

### 4.2 자동 복구 메인 스크립트 (`/opt/db_scripts/failback_gtid.sh`)

```bash
#!/bin/bash
# =========================================================================
#  MariaDB GTID 자동 Failback & VIP 이관 자동화 스크립트 (Production Level)
#  작성일: 2026-05-29 | 작성자: Antigravity AI DBA
# =========================================================================

# --- 1. 외부 설정 파일(.ini) 검증 및 파싱 함수 정의 ---
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

# --- 2. 변수 동적 로드 ---
MASTER_IP=$(get_ini_val "$INI_FILE" "DB_CONFIG" "MASTER_IP")
SLAVE_IP=$(get_ini_val "$INI_FILE" "DB_CONFIG" "SLAVE_IP")
VIP=$(get_ini_val "$INI_FILE" "DB_CONFIG" "VIP")
DB_USER=$(get_ini_val "$INI_FILE" "DB_CONFIG" "DB_USER")
DB_PASS=$(get_ini_val "$INI_FILE" "DB_CONFIG" "DB_PASS")

MYSQL_CMD="mysql -u$DB_USER -p$DB_PASS -h"

echo "[$(date)] === 1단계: 원래 마스터(${MASTER_IP}) 복구 작업 개시 ==="

# --- 3. 슬레이브(임시 Active) 상태 파악 및 마스터 쓰기 제한 ---
echo "[$(date)] 슬레이브(${SLAVE_IP})의 쓰기를 임시 제한하여 데이터 정합성 동결..."
$MYSQL_CMD $SLAVE_IP -e "SET GLOBAL read_only = 1;"

# --- 4. 마스터를 슬레이브의 임시 쫄병(Slave)으로 전환하여 GTID 동기화 수혈 ---
echo "[$(date)] 마스터 DB를 임시 슬레이브로 셋업하여 누락 트랜잭션 수혈..."
$MYSQL_CMD $MASTER_IP -e "STOP SLAVE;"
$MYSQL_CMD $MASTER_IP -e "CHANGE MASTER TO MASTER_HOST='${SLAVE_IP}', MASTER_USER='repl_user', MASTER_PASSWORD='repl_password', MASTER_USE_GTID=slave_pos;"
$MYSQL_CMD $MASTER_IP -e "START SLAVE;"

# --- 5. GTID 동기화 완료 대기 (밀린 로그 제로가 될 때까지 루핑) ---
echo "[$(date)] 슬레이브의 신규 데이터가 마스터로 완벽히 싱크 완료될 때까지 대기..."
while true; do
    # 복제 지연 시간(Seconds_Behind_Master) 확인
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

# --- 6. 가상 IP(VIP) 이관 제어 (수동 Failback) ---
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
    ssh root@$MASTER_IP "ip addr add ${VIP}/27 dev ens36"
fi

# 슬레이브의 Keepalived를 다시 기동하여 BACKUP 상태로 복귀
ssh root@$SLAVE_IP "systemctl start keepalived"

# --- 7. 원래 복제 방향(Topology) 최종 정상화 및 락 해제 ---
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

## 5. [Step 4] 장애 상황 시나리오별 검증 매뉴얼

본 구현 가이드가 프로덕션에 적용된 후 장애 시의 복구 검증 시나리오입니다.

### 5.1 마스터 DB 서비스 중단 시 (자동 Failover 검증)
1. **행동**: `systemctl stop mariadb` (마스터 서버)
2. **현상**: 슬레이브 DB가 3초 이내에 VIP(`10.10.20.21`)를 인계받고 `read_only = 0`으로 풀립니다. WAS는 계속해서 슬레이브 노드에 데이터 추가/삭제를 지장 없이 수행합니다.

### 5.2 마스터 DB 서비스 재기동 시 (자동 Failback 검증)
1. **행동**: 마스터 MariaDB를 기동시키고, `/opt/db_scripts/failback_gtid.sh` 복구 스크립트를 실행합니다. (Orchestrator 연동 시 자동으로 호출됨)
2. **현상**:
   * 마스터가 슬레이브의 누락된 **GTID 트랜잭션만 기가 막히게 흡수**해 와서 100% 동기화시킵니다.
   * VIP가 자동으로 마스터 서버로 안전하게 돌아옵니다.
   * 복제 방향과 쓰기 권한이 원래 마스터(Active), 슬레이브(Passive, Read-Only) 구조로 원상 복구됩니다.
   * 모니터링 화면(`test.jsp`)에 **접속 물리 IP가 다시 마스터(`10.10.20.4`)로 복귀하고 복제 상태가 초록색 불**로 완벽하게 갱신되는 쾌거를 경험할 수 있습니다!
