<%@ page import="java.sql.*" %>
<%@ page import="javax.naming.*" %>
<%@ page import="javax.sql.*" %>
<%@ page import="java.util.List" %>
<%@ page import="java.util.ArrayList" %>
<%@ page contentType="text/html; charset=UTF-8" %>

<%!
    // XSS 방지를 위한 HTML 이스케이프 헬퍼 메서드
    String escapeHtml(String input) {
        if (input == null) return "";
        return input.replace("&", "&amp;")
                    .replace("<", "&lt;")
                    .replace(">", "&gt;")
                    .replace("\"", "&quot;")
                    .replace("'", "&#x27;");
    }

    String getWasIp() {
        try {
            java.util.Enumeration<java.net.NetworkInterface> interfaces = java.net.NetworkInterface.getNetworkInterfaces();
            while (interfaces.hasMoreElements()) {
                java.net.NetworkInterface ni = interfaces.nextElement();
                java.util.Enumeration<java.net.InetAddress> addresses = ni.getInetAddresses();
                while (addresses.hasMoreElements()) {
                    java.net.InetAddress addr = addresses.nextElement();
                    if (!addr.isLoopbackAddress() && addr.getHostAddress().startsWith("10.10.20")) {
                        return addr.getHostAddress();
                    }
                }
            }
        } catch (Exception e) {
            // 무시
        }
        return "Unknown";
    }
%>

<%
    String wasIp = getWasIp();
    String action = request.getParameter("action");

    // 세션 메시지 로드 및 즉시 삭제
    String message = (String) session.getAttribute("message");
    if (message != null) {
        session.removeAttribute("message");
    }

    // 1. POST 요청 처리 (마스터 서버에 쓰기/삭제 진행)
    if ("POST".equalsIgnoreCase(request.getMethod())) {
        try {
            Context ctx = new InitialContext();
            DataSource ds = (DataSource) ctx.lookup("java:/MariaDBDS");

            if ("delete".equals(action)) {
                String idParam = request.getParameter("id");
                if (idParam != null && !idParam.trim().isEmpty()) {
                    try (Connection conn = ds.getConnection()) {
                        conn.setReadOnly(false);
                        try (PreparedStatement ps = conn.prepareStatement("DELETE FROM testDB.members WHERE id = ?")) {
                            ps.setInt(1, Integer.parseInt(idParam.trim()));
                            ps.executeUpdate();
                            response.setContentType("application/json; charset=UTF-8");
                            out.print("{\"success\":true,\"id\":" + idParam.trim() + "}");
                            return;
                        }
                    }
                }
            } else {
                String name = request.getParameter("name");
                if (name != null && !name.trim().isEmpty()) {
                    String trimmedName = name.trim();
                    if (trimmedName.length() > 100) {
                        trimmedName = trimmedName.substring(0, 100);
                    }
                    try (Connection conn = ds.getConnection()) {
                        conn.setReadOnly(false);
                        try (PreparedStatement ps = conn.prepareStatement(
                                "INSERT INTO testDB.members (name) VALUES (?)",
                                PreparedStatement.RETURN_GENERATED_KEYS)) {
                            ps.setString(1, trimmedName);
                            ps.executeUpdate();
                            ResultSet generatedKeys = ps.getGeneratedKeys();
                            if (generatedKeys.next()) {
                                int newId = generatedKeys.getInt(1);
                                response.setContentType("application/json; charset=UTF-8");
                                out.print("{\"id\":" + newId + ",\"name\":\"" + trimmedName.replace("\"", "\\\"") + "\"}");
                                return;
                            }
                        }
                    }
                }
            }
        } catch (Exception e) {
            response.setContentType("application/json; charset=UTF-8");
            response.setStatus(500);
            out.print("{\"error\":\"" + e.getMessage().replace("\"", "\\\"") + "\"}");
            return;
        }
        response.sendRedirect(request.getContextPath() + "/test.jsp");
        return;
    }

    // 2. GET 요청 처리 (단일 데이터 통합 수집 및 각 노드별 헬스체크 수행)
    List<Object[]> memberList = new ArrayList<>();
    String dbError = null;
    
    boolean masterOk = false;
    String masterMsg = "연결 끊김";
    boolean slaveOk = false;
    String slaveMsg = "연결 끊김";

    try {
        Context ctx = new InitialContext();
        DataSource ds = (DataSource) ctx.lookup("java:/MariaDBDS");

        // [A] Master DB 연결성 테스트 및 데이터 로드
        try (Connection conn = ds.getConnection()) {
            conn.setReadOnly(false); // 읽기/쓰기 커넥션 명시
            try (Statement stmt = conn.createStatement();
                 ResultSet rs = stmt.executeQuery("SELECT * FROM testDB.members ORDER BY id DESC")) {
                while (rs.next()) {
                    memberList.add(new Object[]{rs.getInt("id"), rs.getString("name")});
                }
                masterOk = true;
                masterMsg = "연결 성공 (Read/Write 가능)";
            }
        } catch (Exception e) {
            masterMsg = "연결 실패: " + e.getMessage();
        }

        // [B] Slave DB 연결성 테스트 (Read Only 세션 생성 후 단일 Ping 쿼리 수행)
        try (Connection conn = ds.getConnection()) {
            conn.setReadOnly(true); // 읽기 전용 커넥션 설정 (슬레이브 라우팅 지시)
            try (Statement stmt = conn.createStatement();
                 ResultSet rs = stmt.executeQuery("SELECT 1")) {
                if (rs.next()) {
                    slaveOk = true;
                    slaveMsg = "연결 성공 (Read Only)";
                }
            }
        } catch (Exception e) {
            slaveMsg = "연결 실패: " + e.getMessage();
        }
    } catch (Exception e) {
        dbError = e.getMessage();
    }
%>

<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>DB HA & Replication Monitor</title>
    <!-- Google Fonts 고급스러운 서체 적용 -->
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@300;400;500;600;700&display=swap" rel="stylesheet">
    <style>
        :root {
            --bg-color: #f1f5f9;
            --card-bg: #ffffff;
            --text-primary: #0f172a;
            --text-secondary: #64748b;
            --border-color: #e2e8f0;
            --primary: #4f46e5;
            --primary-hover: #4338ca;
            --success: #10b981;
            --error: #ef4444;
            --warn: #f59e0b;
        }

        * {
            box-sizing: border-box;
            margin: 0;
            padding: 0;
        }

        body {
            font-family: 'Plus Jakarta Sans', system-ui, -apple-system, sans-serif;
            background-color: var(--bg-color);
            color: var(--text-primary);
            padding: 40px 20px;
            line-height: 1.5;
            -webkit-font-smoothing: antialiased;
        }

        .wrapper {
            max-width: 1200px;
            margin: 0 auto;
        }

        /* 헤더 영역 */
        header {
            margin-bottom: 36px;
            text-align: left;
            border-bottom: 1px solid var(--border-color);
            padding-bottom: 24px;
        }

        header h1 {
            font-size: 2.4rem;
            font-weight: 700;
            color: var(--text-primary);
            letter-spacing: -0.03em;
        }

        header p {
            color: var(--text-secondary);
            font-size: 1.05rem;
            margin-top: 6px;
            font-weight: 400;
        }

        /* 3열 대시보드 상태 영역 */
        .dashboard-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
            gap: 24px;
            margin-bottom: 36px;
        }

        .status-card {
            background-color: var(--card-bg);
            border: 1px solid var(--border-color);
            border-radius: 20px;
            padding: 26px 28px;
            box-shadow: 0 10px 25px -5px rgba(0, 0, 0, 0.04), 0 8px 10px -6px rgba(0, 0, 0, 0.04);
            transition: all 0.25s cubic-bezier(0.4, 0, 0.2, 1);
            position: relative;
            overflow: hidden;
        }

        .status-card:hover {
            transform: translateY(-5px);
            box-shadow: 0 20px 30px -10px rgba(0, 0, 0, 0.08);
            border-color: #cbd5e1;
        }

        .status-card::before {
            content: '';
            position: absolute;
            top: 0;
            left: 0;
            width: 5px;
            height: 100%;
        }

        .status-card.was::before { background-color: var(--primary); }
        .status-card.master::before { background-color: var(--success); }
        .status-card.slave::before { background-color: var(--warn); }

        .card-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 18px;
        }

        .card-header-left {
            display: flex;
            align-items: center;
            gap: 10px;
        }

        .card-title {
            font-size: 0.85rem;
            text-transform: uppercase;
            font-weight: 700;
            color: var(--text-secondary);
            letter-spacing: 0.06em;
        }

        /* SVG 아이콘 스타일 */
        .icon {
            width: 20px;
            height: 20px;
            color: var(--text-secondary);
            transition: color 0.25s;
        }

        .status-card:hover .icon {
            color: var(--primary);
        }
        .status-card.master:hover .icon {
            color: var(--success);
        }
        .status-card.slave:hover .icon {
            color: var(--warn);
        }

        /* 펄싱 라이트 (상태 점) */
        .status-badge {
            display: inline-flex;
            align-items: center;
            gap: 8px;
            padding: 6px 14px;
            border-radius: 20px;
            font-size: 0.8rem;
            font-weight: 700;
            transition: all 0.2s ease;
        }

        .status-badge.ok {
            background-color: #ecfdf5;
            color: #047857;
            border: 1px solid #d1fae5;
        }

        .status-badge.fail {
            background-color: #fef2f2;
            color: #b91c1c;
            border: 1px solid #fee2e2;
        }

        .pulse-dot {
            width: 8px;
            height: 8px;
            border-radius: 50%;
            position: relative;
            display: inline-block;
        }

        .ok .pulse-dot { background-color: var(--success); }
        .fail .pulse-dot { background-color: var(--error); }

        .pulse-dot::after {
            content: '';
            width: 100%;
            height: 100%;
            border-radius: 50%;
            position: absolute;
            top: 0;
            left: 0;
            animation: pulse 1.8s infinite ease-in-out;
        }

        .ok .pulse-dot::after { background-color: var(--success); }
        .fail .pulse-dot::after { background-color: var(--error); }

        @keyframes pulse {
            0% { transform: scale(1); opacity: 0.8; }
            100% { transform: scale(2.8); opacity: 0; }
        }

        .status-value {
            font-size: 1.8rem;
            font-weight: 700;
            color: var(--text-primary);
            margin-bottom: 8px;
            letter-spacing: -0.01em;
        }

        .status-desc {
            font-size: 0.88rem;
            color: var(--text-secondary);
            word-break: break-all;
            font-weight: 500;
        }

        /* 하단 컨텐츠 레이아웃 */
        .content-layout {
            display: flex;
            flex-direction: column;
            gap: 32px;
        }

        @media (min-width: 900px) {
            .content-layout {
                flex-direction: row;
                align-items: flex-start;
            }
            .form-box {
                width: 380px;
                flex-shrink: 0;
            }
            .table-box {
                flex-grow: 1;
            }
        }

        .card-box {
            background-color: var(--card-bg);
            border: 1px solid var(--border-color);
            border-radius: 20px;
            padding: 32px;
            box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.02), 0 2px 4px -1px rgba(0, 0, 0, 0.02);
            transition: all 0.25s ease-in-out;
        }

        .card-box:hover {
            box-shadow: 0 10px 20px -5px rgba(0, 0, 0, 0.04);
        }

        .card-box h3 {
            font-size: 1.35rem;
            font-weight: 700;
            color: var(--text-primary);
            margin-bottom: 24px;
            letter-spacing: -0.02em;
        }

        /* 메시지 팝업 형태 알림 */
        .alert-box {
            padding: 16px 20px;
            border-radius: 12px;
            font-size: 0.92rem;
            font-weight: 600;
            margin-bottom: 28px;
            display: flex;
            align-items: center;
            box-shadow: 0 4px 12px rgba(0, 0, 0, 0.02);
        }

        .alert-box.message {
            background-color: #ecfdf5;
            color: #065f46;
            border-left: 5px solid var(--success);
        }

        .alert-box.error {
            background-color: #fef2f2;
            color: #991b1b;
            border-left: 5px solid var(--error);
        }

        /* 폼 요소 스타일 */
        .form-group {
            display: flex;
            flex-direction: column;
            gap: 10px;
            margin-bottom: 20px;
        }

        .form-group label {
            font-size: 0.88rem;
            font-weight: 700;
            color: var(--text-secondary);
        }

        input[type=text] {
            padding: 14px 18px;
            border: 2px solid var(--border-color);
            border-radius: 10px;
            font-size: 1rem;
            font-family: inherit;
            outline: none;
            transition: all 0.25s ease-in-out;
            width: 100%;
        }

        input[type=text]:focus {
            border-color: var(--primary);
            box-shadow: 0 0 0 4px rgba(79, 70, 229, 0.15);
            background-color: #fff;
        }

        .btn-submit {
            padding: 14px 20px;
            background: linear-gradient(135deg, var(--primary) 0%, var(--primary-hover) 100%);
            color: white;
            border: none;
            cursor: pointer;
            border-radius: 10px;
            font-weight: 600;
            font-size: 0.98rem;
            font-family: inherit;
            width: 100%;
            transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
            box-shadow: 0 4px 14px rgba(79, 70, 229, 0.25);
        }

        .btn-submit:hover {
            transform: translateY(-1px);
            box-shadow: 0 6px 20px rgba(79, 70, 229, 0.35);
        }

        .btn-submit:active {
            transform: translateY(1px);
            box-shadow: 0 2px 8px rgba(79, 70, 229, 0.2);
        }

        /* 데이터 테이블 스타일 */
        .table-container {
            width: 100%;
            overflow-x: auto;
            border-radius: 12px;
            border: 1px solid var(--border-color);
        }

        table {
            border-collapse: collapse;
            width: 100%;
            text-align: left;
        }

        th, td {
            padding: 18px 24px;
            border-bottom: 1px solid var(--border-color);
            font-size: 0.98rem;
        }

        th {
            background-color: #f8fafc;
            color: var(--text-secondary);
            font-weight: 700;
            text-transform: uppercase;
            font-size: 0.78rem;
            letter-spacing: 0.06em;
        }

        tr:last-child td {
            border-bottom: none;
        }

        tr {
            transition: background-color 0.2s ease;
        }

        tr:hover td {
            background-color: #f8fafc;
        }

        /* 프리미엄 SVG 삭제 아이콘 버튼 */
        .btn-delete {
            display: inline-flex;
            align-items: center;
            justify-content: center;
            width: 38px;
            height: 38px;
            background-color: #fef2f2;
            color: var(--error);
            border: 1px solid #fee2e2;
            cursor: pointer;
            border-radius: 8px;
            transition: all 0.25s cubic-bezier(0.4, 0, 0.2, 1);
        }

        .btn-delete:hover {
            background-color: var(--error);
            color: white;
            border-color: var(--error);
            transform: scale(1.08);
            box-shadow: 0 4px 14px rgba(239, 68, 68, 0.25);
        }

        .btn-delete:active {
            transform: scale(0.95);
        }

        .icon-trash {
            width: 18px;
            height: 18px;
            stroke-width: 2.2;
        }

        .no-data {
            text-align: center;
            color: var(--text-secondary);
            padding: 50px 0;
            font-size: 0.95rem;
            font-weight: 500;
        }
    </style>
</head>
<body>

    <div class="wrapper">
        <header>
            <h1>DB HA & Replication Monitor</h1>
            <p>마스터/슬레이브 데이터베이스 노드별 상태 점검 및 통합 데이터 조회 시스템</p>
        </header>

        <!-- 상단 세션 알림 메시지 영역 -->
        <% if (message != null) { %>
            <div class="alert-box <%= message.startsWith("에러") ? "error" : "message" %>">
                <%= escapeHtml(message) %>
            </div>
        <% } %>

        <% if (dbError != null) { %>
            <div class="alert-box error">
                시스템 오류: <%= escapeHtml(dbError) %>
            </div>
        <% } %>

        <!-- 3열 대시보드 상태 판넬 -->
        <div class="dashboard-grid">
            <!-- WAS Info -->
            <div class="status-card was">
                <div class="card-header">
                    <div class="card-header-left">
                        <!-- Server Icon (SVG) -->
                        <svg xmlns="http://www.w3.org/2000/svg" class="icon" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                            <path stroke-linecap="round" stroke-linejoin="round" d="M5 12h14M5 12a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v4a2 2 0 01-2 2M5 12a2 2 0 00-2 2v4a2 2 0 002 2h14a2 2 0 002-2v-4a2 2 0 00-2-2m-2-4h.01M17 16h.01" />
                        </svg>
                        <span class="card-title">WAS Server</span>
                    </div>
                    <span class="status-badge ok">
                        <span class="pulse-dot"></span> Active
                    </span>
                </div>
                <div class="status-value"><%= escapeHtml(wasIp) %></div>
                <div class="status-desc">현재 어플리케이션이 구동 중인 WAS IP</div>
            </div>

            <!-- Master DB Connection -->
            <div class="status-card master">
                <div class="card-header">
                    <div class="card-header-left">
                        <!-- Database Master Icon (SVG) -->
                        <svg xmlns="http://www.w3.org/2000/svg" class="icon" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                            <path stroke-linecap="round" stroke-linejoin="round" d="M4 7v10c0 2.21 3.582 4 8 4s8-1.79 8-4V7M4 7c0 2.21 3.582 4 8 4s8-1.79 8-4M4 7c0-2.21 3.582-4 8-4s8 1.79 8 4m0 5c0 2.21-3.582 4-8 4s-8-1.79-8-4" />
                        </svg>
                        <span class="card-title">Master DB (10.10.20.4)</span>
                    </div>
                    <span class="status-badge <%= masterOk ? "ok" : "fail" %>">
                        <span class="pulse-dot"></span> <%= masterOk ? "Online" : "Offline" %>
                    </span>
                </div>
                <div class="status-value"><%= masterOk ? "연결 완료" : "연결 유실" %></div>
                <div class="status-desc"><%= escapeHtml(masterMsg) %></div>
            </div>

            <!-- Slave DB Connection -->
            <div class="status-card slave">
                <div class="card-header">
                    <div class="card-header-left">
                        <!-- Sync/Replica Icon (SVG) -->
                        <svg xmlns="http://www.w3.org/2000/svg" class="icon" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                            <path stroke-linecap="round" stroke-linejoin="round" d="M4 4v5h.582m15.356 2A8.001 8.001 0 1121.21 8H18.5M4 4h4.5M4 9a9 9 0 0113.687-3.687" />
                        </svg>
                        <span class="card-title">Slave DB (10.10.20.5)</span>
                    </div>
                    <span class="status-badge <%= slaveOk ? "ok" : "fail" %>">
                        <span class="pulse-dot"></span> <%= slaveOk ? "Online" : "Offline" %>
                    </span>
                </div>
                <div class="status-value"><%= slaveOk ? "연결 완료" : "연결 유실" %></div>
                <div class="status-desc"><%= escapeHtml(slaveMsg) %></div>
            </div>
        </div>

        <!-- 하단 메인 레이아웃 -->
        <div class="content-layout">
            <!-- 좌측 등록 폼 카드 -->
            <div class="card-box form-box">
                <h3>신규 데이터 등록</h3>
                <form id="insert-form" onsubmit="insertRow(event)">
                    <input type="hidden" name="action" value="insert" />
                    <div class="form-group">
                        <label for="input-name">이름</label>
                        <input type="text" id="input-name" name="name" placeholder="등록할 이름을 입력하세요" required />
                    </div>
                    <button type="submit" class="btn-submit">Master DB에 저장</button>
                </form>
            </div>

            <!-- 우측 데이터 테이블 카드 -->
            <div class="card-box table-box">
                <h3>실시간 통합 데이터 목록</h3>
                <div class="table-container">
                    <table>
                        <thead>
                            <tr>
                                <th style="width: 100px;">ID</th>
                                <th>Name</th>
                                <th style="width: 100px; text-align: center;">작업</th>
                            </tr>
                        </thead>
                        <tbody>
                            <% if (memberList.isEmpty()) { %>
                                <tr>
                                    <td colspan="3" class="no-data">등록된 데이터가 존재하지 않습니다.</td>
                                </tr>
                            <% } else { %>
                                <% for (Object[] m : memberList) { %>
                                    <tr>
                                        <td style="font-weight: 600; color: var(--text-secondary);"><%= m[0] %></td>
                                        <td style="font-weight: 500;"><%= escapeHtml((String)m[1]) %></td>
                                        <td style="text-align: center;">
                                            <button type="button" class="btn-delete" title="데이터 삭제"
                                                onclick="deleteRow(this, '<%= m[0] %>')">
                                                <svg xmlns="http://www.w3.org/2000/svg" class="icon-trash" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                                                    <path stroke-linecap="round" stroke-linejoin="round" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16" />
                                                </svg>
                                            </button>
                                        </td>
                                    </tr>
                                <% } %>
                            <% } %>
                        </tbody>
                    </table>
                </div>
            </div>
        </div>
    </div>

<script>
    function insertRow(e) {
        e.preventDefault();
        const form = document.getElementById('insert-form');
        const nameInput = document.getElementById('input-name');
        const name = nameInput.value.trim();
        if (!name) return;

        const formData = new FormData(form);
        const btn = form.querySelector('button[type=submit]');
        btn.disabled = true;

        fetch('test.jsp', { method: 'POST', body: formData })
            .then(res => res.json())
            .then(data => {
                if (data.error) {
                    alert('오류: ' + data.error);
                    return;
                }
                const tbody = document.querySelector('table tbody');
                const noData = tbody.querySelector('.no-data');
                if (noData) noData.closest('tr').remove();

                const tr = document.createElement('tr');
                tr.innerHTML = `
                    <td style="font-weight:600;color:var(--text-secondary);">${data.id}</td>
                    <td style="font-weight:500;">${escapeHtml(data.name)}</td>
                    <td style="text-align:center;">
                        <button type="button" class="btn-delete" title="데이터 삭제"
                            onclick="deleteRow(this, '${data.id}')">
                            <svg xmlns="http://www.w3.org/2000/svg" class="icon-trash" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.2"
                                    d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"/>
                            </svg>
                        </button>
                    </td>`;
                tbody.insertBefore(tr, tbody.firstChild);
                nameInput.value = '';
            })
            .catch(() => alert('통신 오류'))
            .finally(() => { btn.disabled = false; });
    }

    function escapeHtml(str) {
        return str.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
                  .replace(/"/g,'&quot;').replace(/'/g,'&#x27;');
    }

    function deleteRow(btn, id) {
        const formData = new FormData();
        formData.append('action', 'delete');
        formData.append('id', id);

        btn.disabled = true;

        fetch('test.jsp', { method: 'POST', body: formData })
            .then(res => res.json())
            .then(data => {
                if (data.success) {
                    btn.closest('tr').remove();
                } else {
                    alert('삭제 실패: ' + (data.error || '알 수 없는 오류'));
                    btn.disabled = false;
                }
            })
            .catch(() => {
                alert('통신 오류');
                btn.disabled = false;
            });
    }
</script>
</body>
</html>
