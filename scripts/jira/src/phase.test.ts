import { describe, it, expect } from 'vitest';
import { PHASES, phaseSwap } from './phase.js';

describe('phaseSwap', () => {
  it('swaps phase:design for phase:sliced and leaves other labels alone', () => {
    expect(phaseSwap(['phase:design', 'held'], 'sliced')).toEqual({ labels: [{ remove: 'phase:design' }, { add: 'phase:sliced' }] });
  });

  it('a ticket already holding exactly the phase gets no operation', () => {
    expect(phaseSwap(['phase:sliced'], 'sliced')).toEqual({ labels: [] });
  });

  it('none removes every phase label, a retired name included', () => {
    expect(phaseSwap(['phase:waiting', 'phase:build'], 'none')).toEqual({ labels: [{ remove: 'phase:waiting' }, { remove: 'phase:build' }] });
  });

  it('PHASES is the five names, in order', () => {
    expect([...PHASES]).toEqual(['design', 'ready', 'build', 'sliced', 'last-step']);
  });
});
