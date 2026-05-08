package com.example;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@SpringBootApplication
@RestController
public class HelloApplication {

    public static void main(String[] args) {
        SpringApplication.run(HelloApplication.class, args);
    }

    @GetMapping(value = "/", produces = "text/plain")
    public String root() {
        return """
                Hello from Java!

                If you see this through your Outpost domain, the full-mode CI/CD
                pipeline is working: git push -> Tekton build -> registry ->
                ArgoCD sync -> Traefik -> here.
                """;
    }

    @GetMapping(value = "/healthz", produces = "text/plain")
    public String healthz() {
        return "ok\n";
    }
}
