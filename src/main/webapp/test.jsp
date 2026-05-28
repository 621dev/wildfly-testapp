<%@ page import="java.sql.*" %>
<%@ page import="javax.naming.*" %>
<%@ page import="javax.sql.*" %>
<%@ page contentType="text/html; charset=UTF-8" %>

<%! 
    // WAS IP를 알아내는 헬퍼 메서드
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

    // POST 요청 처리: 신규 데이터 추가
    if ("POST".equalsIgnoreCase(request.getMethod())) { 
        String name = request.getParameter("name"); 
        if (name != null && !name.trim().isEmpty()) { 
            try { 
                Context ctx = new InitialContext(); 
                DataSource ds = (DataSource) ctx.lookup("java:/MariaDBDS"); 
                
                // try-with-resources 구문으로 Connection 및 PreparedStatement의 완벽한 자동 close 보장
                try (Connection conn = ds.getConnection();
                     PreparedStatement ps = conn.prepareStatement("INSERT INTO testDB.members (name) VALUES (?)")) {
                    
                    conn.setReadOnly(false);
                    ps.setString(1, name.trim()); 
                    ps.executeUpdate(); 
                    session.setAttribute("message", "'" + name + "' 저장 완료!"); 
                }
            } catch (Exception e) {
                session.setAttribute("message", "에러: " + e.getMessage()); 
            } 
        }
        response.sendRedirect(request.getContextPath() + "/test.jsp"); 
        return; 
    } 

    // 세션 메시지 조회 및 즉시 삭제 (Flash attributes 효과)
    String message = (String) session.getAttribute("message"); 
    if (message != null) {
        session.removeAttribute("message"); 
    }
%>

<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <title>DB 테스트</title>
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            margin: 40px;
            background-color: #f8fafc;
            color: #1e293b;
        }

        .was-info {
            background: #1e293b;
            color: #f8fafc;
            padding: 12px 24px;
            border-radius: 8px;
            display: inline-block;
            margin-bottom: 24px;
            font-weight: 600;
            box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1);
        }

        h2 {
            color: #0f172a;
            font-size: 1.8rem;
            margin-bottom: 1rem;
        }

        form {
            margin-bottom: 30px;
            display: flex;
            gap: 10px;
        }

        input[type=text] {
            padding: 10px 16px;
            width: 250px;
            border: 1px solid #cbd5e1;
            border-radius: 6px;
            font-size: 1rem;
            outline: none;
            transition: border-color 0.2s;
        }

        input[type=text]:focus {
            border-color: #3b82f6;
        }

        input[type=submit] {
            padding: 10px 20px;
            background: #2563eb;
            color: white;
            border: none;
            cursor: pointer;
            border-radius: 6px;
            font-weight: 600;
            font-size: 1rem;
            transition: background 0.2s;
        }

        input[type=submit]:hover {
            background: #1d4ed8;
        }

        .container {
            display: flex;
            gap: 40px;
        }

        .box {
            flex: 1;
            background: white;
            border-radius: 12px;
            padding: 24px;
            box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1), 0 2px 4px -2px rgba(0, 0, 0, 0.1);
        }

        h3 {
            color: white;
            padding: 12px;
            border-radius: 8px;
            margin-top: 0;
            margin-bottom: 16px;
            font-size: 1.2rem;
            font-weight: 600;
        }

        .master h3 {
            background: linear-gradient(135deg, #3b82f6 0%, #1d4ed8 100%);
        }

        .slave h3 {
            background: linear-gradient(135deg, #f97316 0%, #c2410c 100%);
        }

        table {
            border-collapse: collapse;
            width: 100%;
            margin-top: 10px;
        }

        th, td {
            border-bottom: 1px solid #e2e8f0;
            padding: 12px;
            text-align: left;
        }

        th {
            background-color: #f1f5f9;
            color: #475569;
            font-weight: 600;
        }

        tr:hover {
            background-color: #f8fafc;
        }

        .message {
            color: #16a34a;
            background: #dcfce7;
            border-left: 4px solid #16a34a;
            padding: 12px;
            border-radius: 6px;
            font-weight: bold;
            margin: 15px 0;
        }

        .error {
            color: #dc2626;
            background: #fee2e2;
            border-left: 4px solid #dc2626;
            padding: 12px;
            border-radius: 6px;
            font-weight: bold;
            margin: 15px 0;
        }
    </style>
</head>
<body>

    <div class="was-info">
        현재 WAS IP : <%= wasIp %>
    </div>
    
    <h2>데이터 입력</h2>
    <form method="post" action="test.jsp">
        <input type="text" name="name" placeholder="이름 입력" required />
        <input type="submit" value="저장" />
    </form>
    
    <% if (message != null) { %>
        <!-- "에러"로 정상 시작 시 error 클래스가 되도록 조건식 수정 -->
        <p class="<%= message.startsWith("에러") ? "error" : "message" %>">
            <%= message %>
        </p>
    <% } %>
    
    <div class="container">
        <%
            // GET 요청 처리: Master 및 Slave 데이터베이스 동시 조회
            try {
                Context ctx = new InitialContext();
                DataSource ds = (DataSource) ctx.lookup("java:/MariaDBDS");
                
                // try-with-resources 구문으로 모든 DB 리소스의 완전 자동 close 보장
                try (Connection masterConn = ds.getConnection();
                     Statement masterStmt = masterConn.createStatement();
                     ResultSet masterRs = masterStmt.executeQuery("SELECT * FROM testDB.members ORDER BY id DESC");
                     
                     Connection slaveConn = ds.getConnection();
                     Statement slaveStmt = slaveConn.createStatement();
                     ResultSet slaveRs = slaveStmt.executeQuery("SELECT * FROM testDB.members ORDER BY id DESC")) {
                     
                     masterConn.setReadOnly(false);
                     slaveConn.setReadOnly(true);
        %>
        
            <!-- Master DB 정보 영역 -->
            <div class="box master">
                <h3>Master (10.10.20.4)</h3>
                <table>
                    <thead>
                        <tr>
                            <th>ID</th>
                            <th>Name</th>
                        </tr>
                    </thead>
                    <tbody>
                        <% while(masterRs.next()) { %>
                            <tr>
                                <td><%= masterRs.getInt("id") %></td>
                                <td><%= masterRs.getString("name") %></td>
                            </tr>
                        <% } %>
                    </tbody>
                </table>
            </div>
            
            <!-- Slave DB 정보 영역 -->
            <div class="box slave">
                <h3>Slave (10.10.20.5)</h3>
                <table>
                    <thead>
                        <tr>
                            <th>ID</th>
                            <th>Name</th>
                        </tr>
                    </thead>
                    <tbody>
                        <% while(slaveRs.next()) { %>
                            <tr>
                                <td><%= slaveRs.getInt("id") %></td>
                                <td><%= slaveRs.getString("name") %></td>
                            </tr>
                        <% } %>
                    </tbody>
                </table>
            </div>
            
        <% 
                } // try-with-resources close
            } catch (Exception e) { 
        %>
            <p class="error">데이터베이스 조회 중 에러 발생: <%= e.getMessage() %></p>
        <% 
            } 
        %>
    </div>

</body>
</html>