# Implementation Plan: 3노드 MariaDB Galera Cluster 구축 (DB 2대 + Garbd 1대)

본 계획서는 현재 이중화 구성(Master-Slave 복제 + Keepalived VIP)을 동기식 액티브-액티브 고가용성 클러스터 솔루션인 **MariaDB Galera Cluster**로 전면 전환하고, 부족한 노드 정족수(Quorum) 문제를 해결하기 위해 WAS 서버 상에 **Garbd(중재자)**를 얹어 완벽하고 완벽하게 안전한 3노드 결정을 내리는 상세 이행 계획입니다.

---

## User Review Required

> [!IMPORTANT]
> **1. 기존 데이터의 완전 백업 필수**
> * Galera Cluster를 최초 부트스트랩(Bootstrap)할 때 데이터 디렉토리를 초기화하거나 동기화(SST)하는 과정에서 기존 데이터가 손상될 위험이 있습니다. 반드시 **DB 복제 전환 전에 기존 마스터(`10.10.20.4`)의 데이터를 SQL 덤프(`mysqldump`) 형태로 완전히 백업**해야 합니다.
>
> **2. 추가적인 포트 방화벽 개방 필요**
> * Galera Cluster는 SQL 포트(`3306`) 외에 노드 간 동적 동기화를 위해 다음 **3가지 특수 포트**를 사용합니다. 각 DB 서버 및 WAS(Garbd) 서버의 방화벽에서 이 포트들을 서로 완벽하게 열어주어야 합니다:
>   * `4567/tcp,udp` : Galera 클러스터 내부 복제 통신 (가장 중요)
>   * `4568/tcp` : 증분 상태 전송 (IST)
>   * `4444/tcp` : 전체 상태 전송 (SST, rsync/mariabackup)
>
> **3. 기존 Master-Slave 복제 중단**
> * 클러스터가 구축되면 MariaDB 엔진 수준에서 실시간 동기화가 일어나므로, 기존의 비동기식 복제(`replica` 또는 `slave` 스레드) 관련 설정과 명령(`STOP SLAVE; RESET SLAVE ALL;`)을 수행하여 기존 복제 계선 관계를 완전히 끊어내야 합니다.

---

## Proposed Changes

### [Component 1] DB Node 1 (10.10.20.4) & DB Node 2 (10.10.20.5)

MariaDB 10.3 Galera 환경 활성화를 위해 설정 파일 수정 및 클러스터 구성을 추진합니다.

#### [MODIFY] DB 서버 설정 파일 (`/etc/my.cnf.d/server.cnf` 또는 `/etc/my.cnf`)

**1) DB Node 1 (`10.10.20.4`) 설정 변경**:
```ini
[galera]
wsrep_on=ON
wsrep_provider=/usr/lib64/galera/libgalera_smm.so   # Galera 라이브러리 경로 (버전 및 OS에 따라 대조 필수)
wsrep_cluster_name="mariadb_galera_cluster"
# 클러스터 참여하는 전체 노드 IP 목록 (Garbd 포함 총 3개 IP 명시)
wsrep_cluster_address="gcomm://10.10.20.4,10.10.20.5,10.10.20.2"
wsrep_node_name="db-node1"
wsrep_node_address="10.10.20.4"
wsrep_sst_method=rsync                               # 동기화 방식 지정
binlog_format=ROW                                    # Galera 필수 바이너리 로그 포맷
default_storage_engine=InnoDB                        # InnoDB 엔진 필수 사용
innodb_autoinc_lock_mode=2                           # Galera 락 튜닝 필수
```

**2) DB Node 2 (`10.10.20.5`) 설정 변경**:
```ini
[galera]
wsrep_on=ON
wsrep_provider=/usr/lib64/galera/libgalera_smm.so
wsrep_cluster_name="mariadb_galera_cluster"
wsrep_cluster_address="gcomm://10.10.20.4,10.10.20.5,10.10.20.2"
wsrep_node_name="db-node2"
wsrep_node_address="10.10.20.5"
wsrep_sst_method=rsync
binlog_format=ROW
default_storage_engine=InnoDB
innodb_autoinc_lock_mode=2
```

---

### [Component 2] WAS Server (10.10.20.2 - Garbd 중재자 설정)

데이터 저장소 없이 의사결정 투표권(1표)만 전담하는 **Galera Arbitrator(Garbd)**를 WAS 서버에 가볍게 실행시킵니다.

#### [NEW] WAS 서버 내 `garbd` 환경 설정 및 데몬 서비스 구동
CentOS/RHEL 환경 기준으로 `pcp` 또는 `mariadb-bench` 혹은 공식 리포지토리로부터 `galera` 패키지에 함께 내장되어 있는 `garbd` 바이너리를 획득하여 구동 설정을 수립합니다.

1. **설정 파일 생성 (`/etc/sysconfig/garb`)**:
   ```ini
   # Galera Arbitrator configuration
   GALERA_NODES="10.10.20.4:4567,10.10.20.5:4567"  # 조인할 DB 노드들의 주소
   GALERA_GROUP="mariadb_galera_cluster"           # 클러스터 그룹명 동일 매칭
   # GALERA_OPTIONS=""
   LOG_FILE="/var/log/garb.log"
   ```
2. **서비스 실행 및 부팅 등록**:
   ```bash
   systemctl start garb
   systemctl enable garb
   ```

---

## Verification Plan

클러스터가 가동되었을 때 동기화가 실시간으로 잘 이루어지는지 정밀하게 검증합니다.

### 1단계: 방화벽 개방 및 통신 확인 (각 노드 공통)
모든 노드 간의 Galera 포트(`4567`, `4568`, `4444`)가 서로 잘 뚫렸는지 통신 점검을 수행합니다.
```bash
firewall-cmd --permanent --add-port=4567/tcp
firewall-cmd --permanent --add-port=4567/udp
firewall-cmd --permanent --add-port=4568/tcp
firewall-cmd --permanent --add-port=4444/tcp
firewall-cmd --reload
```

### 2단계: 클러스터 부트스트랩 (최초 1회 기상 - DB Node 1에서만)
모든 DB 서비스를 일단 종료한 후, **DB Node 1**을 클러스터 창시자로 기상시킵니다.
```bash
# DB Node 1에서 실행 (최초 클러스터 생성 명령어)
galera_new_cluster
# (또는 systemctl start mariadb --wsrep-new-cluster)
```

### 3단계: 조인 노드 순차 기동 (DB Node 2 및 Garbd)
1. **DB Node 2**에서 MariaDB를 일반 기동하여 1번 노드로부터 데이터를 완전 자동 동기화(SST)받게 만듭니다:
   ```bash
   systemctl start mariadb
   ```
2. **WAS 서버**에서 `garb` 서비스를 켜서 투표 멤버로 클러스터에 최종 진입시킵니다.

### 4단계: 실시간 동기화 및 Quorum 검증 (DB 명령)
DB Node 1 또는 2에 접속하여 클러스터 상태와 의결 노드 개수가 **`3`**으로 완벽하게 연동되었는지 확인합니다:
```sql
SHOW STATUS LIKE 'wsrep_cluster_size'; -- 결과값이 '3'으로 나와야 함!
SHOW STATUS LIKE 'wsrep_local_state_comment'; -- 'Synced' 상태 확인!
```

이후 한쪽 노드에 데이터를 INSERT 했을 때, 다른 노드에 실시간 동기화되는지 최종 확인합니다.
