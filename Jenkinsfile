pipeline {
    agent any

    tools {
        jdk 'java-21'
    }

    triggers {
        // 5분마다 Git 변경 사항 체크 및 GitHub 웹훅 트리거 활성화
        pollSCM('H/5 * * * *')
        githubPush()
    }

    environment {
        APP_NAME     = 'wildfly-testapp'
        WAR_FILE     = "target/${APP_NAME}.war"
        DEPLOY_DIR   = '/opt/wildfly/standalone/deployments'
        WILDFLY_USER = 'wildflyadm'
    }

    parameters {
        string(name: 'WAS_SERVERS', defaultValue: '10.10.20.2,10.10.20.3', description: 'WildFly 서버 IP (쉼표 구분)')
    }

    stages {

        stage('Checkout') {
            steps {
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
                withCredentials([sshUserPrivateKey(
                    credentialsId: 'wildfly-ssh-key',
                    keyFileVariable: 'SSH_KEY',
                    usernameVariable: 'SSH_USER'
                )]) {
                    script {
                        def servers = params.WAS_SERVERS.split(',').collect { it.trim() }
                        echo "배포 대상 서버: ${servers}"

                        for (server in servers) {
                            echo "===== [${server}] 배포 시작 ====="

                            // 1) 기존 WAR 제거 및 Undeploy 대기 (3초)
                            sh """
                                ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no ${SSH_USER}@${server} \
                                'rm -f ${DEPLOY_DIR}/${APP_NAME}.war ${DEPLOY_DIR}/${APP_NAME}.war.deployed && sleep 3'
                            """

                            // 2) 새 WAR 업로드
                            sh """
                                scp -i ${SSH_KEY} -o StrictHostKeyChecking=no \
                                ${WAR_FILE} ${SSH_USER}@${server}:${DEPLOY_DIR}/
                            """

                            // 3) 배포 완료 대기 (최대 60초)
                            sh """
                                ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no ${SSH_USER}@${server} '
                                    for i in \$(seq 1 30); do
                                        [ -f ${DEPLOY_DIR}/${APP_NAME}.war.deployed ] && echo "[${server}] 배포 성공" && exit 0
                                        [ -f ${DEPLOY_DIR}/${APP_NAME}.war.failed ]   && echo "[${server}] 배포 실패!" && exit 1
                                        sleep 2
                                    done
                                    echo "배포 타임아웃" && exit 1
                                '
                            """

                            echo "===== [${server}] 배포 완료 ====="
                        }
                    }
                }
            }
        }

        stage('Health Check') {
            steps {
                script {
                    def servers = params.WAS_SERVERS.split(',').collect { it.trim() }
                    for (server in servers) {
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
