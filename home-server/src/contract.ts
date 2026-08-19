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
