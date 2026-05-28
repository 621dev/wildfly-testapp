pipeline {
    agent any

    tools {
        jdk 'java-21'
    }

    environment {
        APP_NAME      = 'wildfly-testapp'
        WAR_FILE      = "target/${APP_NAME}.war"
        DEPLOY_DIR    = '/opt/wildfly/standalone/deployments'
        WILDFLY_USER  = 'wildflyadm'                         // WildFly 서버 SSH 계정
    }

    // Jenkins Credentials에 등록한 SSH Private Key ID 목록
    // Manage Jenkins > Credentials 에서 'SSH Username with private key' 타입으로 등록
    // 서버 IP는 실제 WildFly 서버 IP로 변경
    parameters {
        string(name: 'WAS_SERVERS', defaultValue: '10.10.20.2,10.10.20.3', description: 'WildFly 서버 IP (쉼표 구분)')
    }

    stages {

        stage('Checkout') {
            steps {
                // GitHub 저장소에서 소스 체크아웃 (SCM 설정에서 자동 처리)
                checkout scm
                echo "브랜치: ${env.BRANCH_NAME ?: 'main'}"
            }
        }

        stage('Build') {
            steps {
                sh 'mvn clean package -DskipTests'
                archiveArtifacts artifacts: "${WAR_FILE}", fingerprint: true
                echo "빌드 완료: ${WAR_FILE}"
            }
        }

        stage('Rolling Deploy') {
            steps {
                script {
                    def servers = params.WAS_SERVERS.split(',').collect { it.trim() }
                    echo "배포 대상 서버: ${servers}"

                    for (server in servers) {
                        echo "===== [${server}] 배포 시작 ====="

                        // 1) 기존 WAR 제거 (언디플로이 트리거)
                        sshCommand(
                            remote: buildRemote(server),
                            command: "rm -f ${DEPLOY_DIR}/${APP_NAME}.war ${DEPLOY_DIR}/${APP_NAME}.war.deployed"
                        )

                        // 2) 언디플로이 완료 대기
                        sshCommand(
                            remote: buildRemote(server),
                            command: """
                                for i in \$(seq 1 30); do
                                    [ -f ${DEPLOY_DIR}/${APP_NAME}.war.undeployed ] && echo 'undeployed' && break
                                    sleep 2
                                done
                            """
                        )

                        // 3) 새 WAR 업로드
                        sshPut(
                            remote: buildRemote(server),
                            from: "${WAR_FILE}",
                            into: "${DEPLOY_DIR}/"
                        )

                        // 4) 배포 완료 대기 (최대 60초)
                        sshCommand(
                            remote: buildRemote(server),
                            command: """
                                for i in \$(seq 1 30); do
                                    [ -f ${DEPLOY_DIR}/${APP_NAME}.war.deployed ] && echo '[${server}] 배포 성공' && break
                                    [ -f ${DEPLOY_DIR}/${APP_NAME}.war.failed ]   && echo '[${server}] 배포 실패!' && exit 1
                                    sleep 2
                                done
                                [ -f ${DEPLOY_DIR}/${APP_NAME}.war.deployed ] || (echo '배포 타임아웃' && exit 1)
                            """
                        )

                        echo "===== [${server}] 배포 완료 ====="
                    }
                }
            }
        }

        stage('Health Check') {
            steps {
                script {
                    def servers = params.WAS_SERVERS.split(',').collect { it.trim() }
                    for (server in servers) {
                        // 8080 포트로 헬스체크 (컨텍스트 경로는 프로젝트에 맞게 조정)
                        def url = "http://${server}:8080/${APP_NAME}/test.jsp"
                        def status = sh(
                            script: "curl -s -o /dev/null -w '%{http_code}' --max-time 10 '${url}'",
                            returnStdout: true
                        ).trim()
                        if (status != '200') {
                            error "[${server}] 헬스체크 실패 (HTTP ${status}): ${url}"
                        }
                        echo "[${server}] 헬스체크 통과 (HTTP ${status})"
                    }
                }
            }
        }
    }

    post {
        success {
            echo "배포 성공: ${APP_NAME} v${env.BUILD_NUMBER}"
        }
        failure {
            echo "배포 실패 — Jenkins 로그를 확인하세요."
        }
    }
}

// SSH 접속 정보 객체 생성 헬퍼
// Jenkins Credentials에 'wildfly-ssh-key' ID로 SSH 키를 등록해야 합니다
def buildRemote(String host) {
    return [
        name        : host,
        host        : host,
        user        : env.WILDFLY_USER,
        credentialsId: 'wildfly-ssh-key',   // Jenkins Credentials ID
        allowAnyHosts: true
    ]
}
