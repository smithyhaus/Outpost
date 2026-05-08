export default function App() {
  return (
    <main
      style={{
        fontFamily: 'system-ui, -apple-system, sans-serif',
        maxWidth: 640,
        margin: '4rem auto',
        padding: '0 1.5rem',
        lineHeight: 1.5,
      }}
    >
      <h1>Hello from React</h1>
      <p>
        If you are seeing this through your Outpost domain, the full-mode
        CI/CD pipeline is working end-to-end:
        git push → Tekton build → registry → ArgoCD sync → Traefik → here.
      </p>
      <p style={{ color: '#666', fontSize: '0.9rem' }}>
        Health endpoint: <code>/healthz</code>
      </p>
    </main>
  );
}
