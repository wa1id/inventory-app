/**
 * The port: the single interface every vision provider is adapted to.
 *
 * This is the Strategy/Ports-and-Adapters seam. The HTTP layer, the prompt, and
 * the wire contract all depend on *this* type — never on a vendor SDK. Adding a
 * provider means writing one module that satisfies `VisionAdapter` and
 * registering it; nothing else in the codebase changes.
 */

/** Image handed to an adapter, already decoded from the wire format. */
export interface VisionImage {
  /** Raw bytes. Adapters convert to whatever their provider expects. */
  bytes: Uint8Array;
  /** IANA media type, e.g. `image/jpeg`. */
  mediaType: string;
}

/**
 * What a provider extracted, before contract-level normalization.
 *
 * Deliberately loose — normalizing and clamping happens once, centrally, so a
 * new adapter cannot invent its own idea of a valid suggestion.
 */
export interface RawSuggestion {
  name: string | null;
  category: string | null;
  tags: string[];
  estimatedValue: number | null;
  currency: string | null;
  /** 0–1. Adapters must not fabricate certainty they do not have. */
  confidence: number;
}

/**
 * Why an adapter failed, in terms the HTTP layer can map to the client's
 * failure taxonomy. Providers report errors very differently; each adapter is
 * responsible for classifying its own into these three buckets.
 */
export type AdapterErrorKind = 'timeout' | 'rate_limited' | 'upstream';

export type AdapterOutcome =
  | { status: 'ok'; suggestion: RawSuggestion }
  /** The model looked and genuinely could not identify the item. */
  | { status: 'unrecognized' }
  | { status: 'error'; kind: AdapterErrorKind; message: string };

export interface RecognizeOptions {
  image: VisionImage;
  /** Aborts the provider call when the request budget is exhausted. */
  signal: AbortSignal;
}

export interface VisionAdapter {
  /** Stable identifier used to select this adapter. */
  readonly id: string;
  /** Human-readable, for logs and the health endpoint. */
  readonly label: string;
  recognize(options: RecognizeOptions): Promise<AdapterOutcome>;
}

/** Adapters are constructed lazily so an unused one never reads config. */
export type AdapterFactory = () => VisionAdapter;
