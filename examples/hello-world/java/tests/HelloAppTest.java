// hello-world-java smoke tests (Spring Boot Test + JUnit 5).
// Phase 2: move to src/test/java/HelloAppTest.java and enable
// `mvn test` in outpost.test.yaml.
package com.outpost.hello;

import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;

import static org.assertj.core.api.Assertions.assertThat;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class HelloAppTest {

    @LocalServerPort
    private int port;

    @Autowired
    private TestRestTemplate restTemplate;

    @Test
    void healthzReturnsOk() {
        ResponseEntity<String> r =
            restTemplate.getForEntity("http://localhost:" + port + "/healthz", String.class);
        assertThat(r.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(r.getBody()).contains("ok");
    }

    @Test
    void rootReturnsGreeting() {
        ResponseEntity<String> r =
            restTemplate.getForEntity("http://localhost:" + port + "/", String.class);
        assertThat(r.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(r.getBody()).contains("Hello from Java");
    }
}
