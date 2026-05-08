package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
)

const greeting = `Hello from Go!

If you see this through your Outpost domain, the full-mode CI/CD
pipeline is working: git push -> Tekton build -> registry ->
ArgoCD sync -> Traefik -> here.
`

func main() {
	addr := envOr("ADDR", ":8080")

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		fmt.Fprintln(w, "ok")
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		_, _ = w.Write([]byte(greeting))
	})

	log.Printf("hello-go listening on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal(err)
	}
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
