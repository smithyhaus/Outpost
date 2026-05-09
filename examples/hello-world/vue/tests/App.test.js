// hello-world-vue smoke tests (vitest + @vue/test-utils).
// Phase 2: enable by adding vitest + @vue/test-utils to devDependencies
// and flipping outpost.test.yaml runner.command to `npm test -- --run`.
import { describe, it, expect } from 'vitest';
import { mount } from '@vue/test-utils';
import App from '../src/App.vue';

describe('App', () => {
  it('renders the greeting', () => {
    const wrapper = mount(App);
    expect(wrapper.find('h1').exists()).toBe(true);
  });

  it('mentions Vue', () => {
    const wrapper = mount(App);
    expect(wrapper.text()).toMatch(/Vue/);
  });
});
