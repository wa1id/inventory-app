/**
 * In-process revision counter. Focus-refetch is the real live-update
 * guarantee; SSE just pushes this number so a client can skip a round trip
 * when nothing changed.
 */
export interface RevisionHub {
  readonly revision: number;
  bump(): void;
  subscribe(listener: (revision: number) => void): () => void;
}

export function createRevisionHub(): RevisionHub {
  let revision = 0;
  const listeners = new Set<(revision: number) => void>();

  return {
    get revision() {
      return revision;
    },
    bump() {
      revision += 1;
      for (const listener of listeners) listener(revision);
    },
    subscribe(listener) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
  };
}
