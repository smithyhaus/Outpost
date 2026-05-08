<template>
  <main>
    <h1>Hello from Vue</h1>
    <p>
      If you are seeing this through your Outpost domain, the full-mode
      CI/CD pipeline is working end-to-end:
      git push → Tekton build → registry → ArgoCD sync → Traefik → here.
    </p>
    <p class="hint">Health endpoint: <code>/healthz</code></p>
  </main>
</template>

<style>
main {
  font-family: system-ui, -apple-system, sans-serif;
  max-width: 640px;
  margin: 4rem auto;
  padding: 0 1.5rem;
  line-height: 1.5;
}
.hint {
  color: #666;
  font-size: 0.9rem;
}
</style>
