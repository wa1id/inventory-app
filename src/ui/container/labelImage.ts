import { File, Paths } from 'expo-file-system';

/** The part of react-native-svg's `Svg` that can draw itself as a picture. */
export interface QrSvg {
  toDataURL: (
    callback: (base64: string) => void,
    options?: { width: number; height: number },
  ) => void;
}

/** Sharp enough to print a label a few centimetres wide. */
const PICTURE_PX = 1024;

/** `toDataURL` reports through a callback only; never wait on it for ever. */
const PICTURE_TIMEOUT_MS = 4000;

function snapshot(svg: QrSvg): Promise<string> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('qr_picture_timeout')), PICTURE_TIMEOUT_MS);
    try {
      svg.toDataURL(
        (data) => {
          clearTimeout(timer);
          // Native returns bare base64; the web returns a data URL.
          resolve(data.replace(/^data:[^,]*,/, ''));
        },
        { width: PICTURE_PX, height: PICTURE_PX },
      );
    } catch (error) {
      clearTimeout(timer);
      reject(error);
    }
  });
}

/**
 * Saves the label's QR code as a PNG in the cache and returns its URI, so the
 * iOS share sheet offers Save Image and Print rather than only a line of
 * text. No new native module: react-native-svg draws it and
 * expo-file-system writes it. The file is overwritten on the next share and
 * the system may clear the cache whenever it likes.
 */
export async function writeLabelPicture(svg: QrSvg, shortCode: string): Promise<string> {
  const base64 = await snapshot(svg);
  const name = shortCode.replace(/[^A-Za-z0-9-]/g, '') || 'label';
  const file = new File(Paths.cache, `label-${name}.png`);
  if (file.exists) file.delete();
  file.create();
  file.write(base64, { encoding: 'base64' });
  return file.uri;
}
