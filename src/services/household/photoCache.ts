import { householdFetch, type HouseholdSession } from './client';

/**
 * Household photo bytes live in R2. Screens still want a `file://` URI for
 * `<Image>`. Cache under the photo id so a list row does not re-download
 * every focus.
 *
 * expo-file-system is loaded lazily so logic tests that never resolve a photo
 * do not pull React Native through the Node Jest project.
 */
export async function resolveHouseholdPhoto(options: {
  session: HouseholdSession;
  photoId: string;
  kind: 'full' | 'thumb';
  fetchImpl?: typeof fetch;
}): Promise<string | null> {
  try {
    const { Directory, File, Paths } = await import('expo-file-system');
    const dir = new Directory(Paths.cache, 'household-photos');
    if (!dir.exists) dir.create({ intermediates: true });
    const name =
      options.kind === 'thumb' ? `${options.photoId}-thumb.webp` : `${options.photoId}.webp`;
    const file = new File(dir, name);
    if (file.exists) return file.uri;

    const response = await householdFetch({
      origin: options.session.origin,
      token: options.session.token,
      path: `/v1/photos/${encodeURIComponent(options.photoId)}${options.kind === 'thumb' ? '?thumb=1' : ''}`,
      fetchImpl: options.fetchImpl,
    });
    if (!response.ok) return null;
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (file.exists) file.delete();
    file.create();
    file.write(bytes);
    return file.uri;
  } catch {
    return null;
  }
}

/** After a local capture is POSTed, remember the files under the server photo id. */
export async function rememberHouseholdPhoto(
  photoId: string,
  sourceUri: string,
  thumbUri?: string | null,
): Promise<void> {
  try {
    const { Directory, File, Paths } = await import('expo-file-system');
    const dir = new Directory(Paths.cache, 'household-photos');
    if (!dir.exists) dir.create({ intermediates: true });
    copyIfPresent(File, sourceUri, new File(dir, `${photoId}.webp`));
    if (thumbUri) copyIfPresent(File, thumbUri, new File(dir, `${photoId}-thumb.webp`));
  } catch {
    // Display will fall back to fetching from the household API.
  }
}

function copyIfPresent(
  FileCtor: typeof import('expo-file-system').File,
  sourceUri: string,
  destination: InstanceType<typeof import('expo-file-system').File>,
): void {
  const source = new FileCtor(sourceUri);
  if (!source.exists) return;
  if (destination.exists) destination.delete();
  source.copy(destination);
}
