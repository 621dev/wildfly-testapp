package com.example.wildflytest;

import jakarta.servlet.ServletException;
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.io.PrintWriter;

@WebServlet(name = "HelloServlet", value = "/hello")
public class HelloServlet extends HttpServlet {

    @Override
    protected void doGet(HttpServletRequest request, HttpServletResponse response) throws ServletException, IOException {
        response.setContentType("text/html;charset=UTF-8");
        try (PrintWriter out = response.getWriter()) {
            out.println("<!DOCTYPE html>");
            out.println("<html>");
            out.println("<head>");
            out.println("<title>Hello WildFly</title>");
            out.println("<style>");
            out.println("body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: #f4f7f6; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }");
            out.println(".card { background: white; padding: 40px; border-radius: 12px; box-shadow: 0 4px 20px rgba(0,0,0,0.1); text-align: center; }");
            out.println("h1 { color: #00768f; margin-bottom: 10px; }");
            out.println("p { color: #555; }");
            out.println("</style>");
            out.println("</head>");
            out.println("<body>");
            out.println("<div class='card'>");
            out.println("<h1>Hello from WildFly!</h1>");
            out.println("<p>Your Jakarta EE 10 Maven Web Application is running successfully.</p>");
            out.println("</div>");
            out.println("</body>");
            out.println("</html>");
        }
    }
}
