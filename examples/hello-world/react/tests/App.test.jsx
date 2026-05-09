// hello-world-react smoke tests (vitest + @testing-library/react).
// Phase 2: enable by adding vitest + @testing-library/react to devDependencies
// and flipping outpost.test.yaml runner.command to `npm test -- --run`.
import { describe, it, expect } from 'vitest';
import { render, screen } from '@testing-library/react';
import App from '../src/App.jsx';

describe('App', () => {
  it('renders the greeting heading', () => {
    render(<App />);
    expect(screen.getByRole('heading', { level: 1 })).toBeInTheDocument();
  });

  it('mentions the CI/CD pipeline', () => {
    render(<App />);
    expect(screen.getByText(/CI\/CD/i)).toBeInTheDocument();
  });
});
