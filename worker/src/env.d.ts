/**
 * Bindings that `wrangler types` cannot see.
 *
 * Secrets are set with `wrangler secret put` and deliberately live nowhere in
 * the checked-in config, so they never appear in the generated
 * `worker-configuration.d.ts`. Declaring them here by interface merging keeps
 * the Worker type-safe without writing the value down.
 */
interface Env {
  /**
   * Shared app key, matching `EXPO_PUBLIC_SYNC_KEY` in the mobile build.
   *
   * Optional on purpose: an unset secret leaves the endpoint open, which is
   * what makes `wrangler dev` usable without a local secret store. The
   * deployment sets it.
   */
  SYNC_SHARED_SECRET?: string;
}
