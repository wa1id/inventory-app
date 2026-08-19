/**
 * Wire contract between paired clients and this household API.
 *
 * Independent of the recognition contract (`server/`) and the old
 * `inventory-sync` contract (`worker/`). Bump this when a paired app would
 * misread a response. Health reports it and nothing else.
 */
export const CONTRACT_VERSION = 1;

/** Host port cloudflared already expects; 8080 is taken on this box. */
export const DEFAULT_PORT = 8788;

/** Existing inventory-sync Worker; it already has the R2 bucket bound. */
export const DEFAULT_PHOTO_WORKER_ORIGIN = 'https://inventory-sync.wyachou95.workers.dev';

/** K18: one household, this name. */
export const HOUSEHOLD_NAME = 'Home';

/** 16 CSPRNG bytes, same size as the old recovery code. */
export const BOOTSTRAP_SECRET_BYTES = 16;

/** Raw device bearer token length. Hex-encoded on the wire. */
export const DEVICE_TOKEN_BYTES = 32;
