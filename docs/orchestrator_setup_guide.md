# Orchestrator Raft 합의 클러스터 설치 및 정석 구축 가이드

본 가이드는 MariaDB 고가용성(HA) 아키텍처의 핵심 브레인 역할을 수행하는 **Orchestrator**를 두 대의 WAS 서버 상에 **Raft 분산 합의 클러스터**로 이중화하고, 보안 접속(SSL/TLS) 및 완전 무인 자동화 장애 복구를 가동하기 위한 상세 인프라 구축 명세서입니다.

---

## 1. 아키텍처 및 포트 구성
* **WAS 1번 서버**: `10.10.20.2` (Hostname: `was1.local`, Orchestrator Raft Node 1)
* **WAS 2번 서버**: `10.10.20.3` (Hostname: `was2.local`, Orchestrator Raft Node 2)
* **대시보드 웹 API 포트**: `3000/tcp` (양 노드 공통)
* **Raft 합의 통신 포트**: `10008/tcp` (양 노드 상호 대화용)

---

## 2. [Step 1] 인프라 환경 구성 및 패키지 설치 (WAS 1, WAS 2 공통)

### 2.1 FQDN 호스트네임 등록
오케스트레이터 및 리눅스 시스템이 IP 주소뿐만 아니라, 정규 호스트명(`db1.local`, `db2.local`)을 명확히 해석할 수 있도록 호스트 테이블을 정의합니다.
```bash
# 1. 각 노드별 Hosts 매핑 추가
vi /etc/hosts

# 아래 정보를 하단에 주입합니다.
10.10.20.4 db1.local db1
10.10.20.5 db2.local db2
10.10.20.2 was1.local was1
10.10.20.3 was2.local was2
```

### 2.2 Orchestrator RPM 패키지 설치
```bash
# GitHub 공식 저장소에서 CentOS/RHEL용 최신 안정버전(v3.2.6) RPM 파일 다운로드
curl -L -O https://github.com/openark/orchestrator/releases/download/v3.2.6/orchestrator-3.2.6-1.x86_64.rpm
dnf localinstall -y orchestrator-3.2.6-1.x86_64.rpm

# 바이너리 및 클라이언트 툴 전역 심볼릭 링크 연결
ln -sf /usr/local/orchestrator/orchestrator /usr/bin/orchestrator
ln -sf /usr/local/orchestrator/resources/bin/orchestrator-client /usr/bin/orchestrator-client

# 권한 그룹 및 전용 기동 유저 생성 및 권한 회수
groupadd -r orchestrator || true
useradd -r -g orchestrator -s /sbin/nologin orchestrator || true
chown -R orchestrator:orchestrator /var/lib/orchestrator
```

### 2.3 방화벽 포트 개방
```bash
# 웹 포트(3000) 및 Raft 합의 포트(10008) 개방
firewall-cmd --permanent --add-port={3000,10008}/tcp
firewall-cmd --reload
```

---

## 3. [Step 2] 2트랙 설정 분리/병합 및 Systemd 정석 기상 구성

실무 가독성을 극대화하기 위해, 수백 줄의 디폴트 JSON 설정 파일인 `/etc/orchestrator.conf.json`은 순수 원본 상태 그대로 보관(초기화)하고, 내가 커스터마이징한 핵심 옵션만 `/etc/orchestrator-custom.json` 파일로 격리하여 상호 병합 구동시킵니다.

### 3.1 베이스 설정 파일 공장 초기화
```bash
# 복잡하게 꼬인 설정 파일을 갓 다운로드받은 깨끗한 순수 샘플 파일로 덮어쓰기
cp -f /usr/local/orchestrator/orchestrator-sample.conf.json /etc/orchestrator.conf.json
```

### 3.2 커스텀 설정 파일 분리 생성 (`/etc/orchestrator-custom.json`)

**1) WAS 1번 서버 (`10.10.20.2`) 설정**:
```json
{
  "ListenAddress": ":3000",
  "BackendDB": "sqlite3",
  "SQLite3DataFile": "/var/lib/orchestrator/orchestrator.db",
  
  // --- [실무 정석] SSL/TLS 활성화 DB 접속 설정 ---
  "MySQLTopologyUser": "orc_user",
  "MySQLTopologyPassword": "orc_password",
  "MySQLTopologyParams": "tls=preferred",
  "MySQLTopologyUseSSL": true,
  "MySQLTopologySSLSkipVerify": true,
  
  // --- [실무 정석] 완전 무인 자동 복구(Auto Failover) 기능 가동 ---
  "AutoMasterRecovery": true,
  "AutoIntermediateMasterRecovery": true,
  "RecoverMasterClusterFilters": [
    "*"
  ],
  "RecoveryPeriodBlockSeconds": 10,
  
  // --- Raft 합의 클러스터 설정 ---
  "RaftEnabled": true,
  "RaftDataDir": "/var/lib/orchestrator",
  "RaftBind": "10.10.20.2:10008",
  "RaftAdvertise": "10.10.20.2",
  "RaftNodes": [
    "10.10.20.2",
    "10.10.20.3"
  ],
  
  // 후처리 자동화 스크립트 연결
  "PostMasterFailoverProcesses": [
    "/opt/db_scripts/failover_completed.sh"
  ],
  "PostGracefulTakeoverProcesses": [
    "/opt/db_scripts/failback_gtid.sh"
  ]
}
```

**2) WAS 2번 서버 (`10.10.20.3`) 설정**:
```json
{
  "ListenAddress": ":3000",
  "BackendDB": "sqlite3",
  "SQLite3DataFile": "/var/lib/orchestrator/orchestrator.db",
  
  "MySQLTopologyUser": "orc_user",
  "MySQLTopologyPassword": "orc_password",
  "MySQLTopologyParams": "tls=preferred",
  "MySQLTopologyUseSSL": true,
  "MySQLTopologySSLSkipVerify": true,
  
  "AutoMasterRecovery": true,
  "AutoIntermediateMasterRecovery": true,
  "RecoverMasterClusterFilters": [
    "*"
  ],
  "RecoveryPeriodBlockSeconds": 10,
  
  "RaftEnabled": true,
  "RaftDataDir": "/var/lib/orchestrator",
  "RaftBind": "10.10.20.3:10008",
  "RaftAdvertise": "10.10.20.3",
  "RaftNodes": [
    "10.10.20.2",
    "10.10.20.3"
  ],
  
  "PostMasterFailoverProcesses": [
    "/opt/db_scripts/failover_completed.sh"
  ],
  "PostGracefulTakeoverProcesses": [
    "/opt/db_scripts/failback_gtid.sh"
  ]
}
```

### 3.3 Systemd 서비스 병합 구동 튜닝
```bash
# 1. systemd 서비스 파일의 ExecStart 라인을 실시간 병합 주입형으로 정밀 치환
sed -i 's|ExecStart=/usr/local/orchestrator/orchestrator http|ExecStart=/usr/local/orchestrator/orchestrator -config /etc/orchestrator.conf.json -config /etc/orchestrator-custom.json http|g' /etc/systemd/system/orchestrator.service

# 2. 데몬 설정 리로드 및 서비스 재시작
systemctl daemon-reload
systemctl restart orchestrator
systemctl enable orchestrator
```

---

## 4. [Step 3] 클라이언트 API 통신 연동 및 최초 스캔 (Discover)
오케스트레이터 CLI 클라이언트 도구가 로컬 포트 `3306`으로 접속을 시도하는 오동작을 원천 방지하고, 3000번 포트로 도는 오케스트레이터 웹 API 서버와 완벽하게 대화하도록 API 환경 설정을 영구 주입합니다.

```bash
# 1. 클라이언트 전용 설정 파일 생성 (WAS 1, WAS 2 공통 실행)
echo 'api="http://127.0.0.1:3000/api"' > /etc/orchestrator-client.conf

# 2. 정식 도메인 기반 최초 스캔 등록 (WAS 1번 서버 쉘에서 딱 1번만 실행)
orchestrator-client -c discover -i db1.local
```

---

## 5. [Trubleshooting] Raft 합의 복제 꼬임 및 유령 노드 박멸 리셋법
구축 도중 호스트명(`localhost.localdomain` 등)이 잘못 들어가 오케스트레이터 내장 합의 데이터베이스가 오염되었을 때, 쿨타임 및 피어 간의 무한 동기화 늪을 깨뜨리고 단 10초 만에 완벽하게 디렉토리를 청정 리셋하는 실무 최고 비법입니다.

```bash
# [양쪽 WAS 서버 1번 & 2번 공통 동시 실행]
# 1. 오케스트레이터 서비스 중지
systemctl stop orchestrator

# 2. 데이터 디렉토리 내의 꼬인 세션 상태, 멤버십, SQLite 파일을 싹 다 강제 제거
rm -rf /var/lib/orchestrator/*

# 3. 디렉토리 소유권 재확보
chown -R orchestrator:orchestrator /var/lib/orchestrator

# 4. 서비스 가동
systemctl start orchestrator

# 5. [WAS 1번 서버에서 딱 1번만 실행] FQDN 정식 최초 스캔
orchestrator-client -c discover -i db1.local
```
