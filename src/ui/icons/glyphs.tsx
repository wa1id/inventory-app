import type { ReactElement } from 'react';
import { Circle, Path, Rect } from 'react-native-svg';

/**
 * Line icons on a 24 × 24 grid, drawn by `Icon` with a 1.75 stroke, round caps
 * and joins and no fill.
 *
 * The first group is copied verbatim from the desk (`home-server/web/index.html:25-90`)
 * so both surfaces draw the same box, drawer and tray. The rest are new in the
 * same style. `h.01` segments render as round dots. There is no emoji anywhere
 * in chrome: the only emoji on screen are people's own space icons.
 */
export const GLYPHS = {
  search: (
    <>
      <Circle cx="10.5" cy="10.5" r="6.25" />
      <Path d="m15.2 15.2 5.3 5.3" />
    </>
  ),
  close: <Path d="M6.5 6.5l11 11M17.5 6.5l-11 11" />,
  back: <Path d="M14.5 5.5 8 12l6.5 6.5" />,
  lock: (
    <>
      <Rect x="5" y="10.5" width="14" height="10" rx="2" />
      <Path d="M8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5" />
    </>
  ),
  menu: <Path d="M4 7h16M4 12h16M4 17h10" />,
  minus: <Path d="M6 12h12" />,
  plus: <Path d="M12 6v12M6 12h12" />,
  edit: (
    <>
      <Path d="M4.5 19.5 5.5 15 15.8 4.7a1.8 1.8 0 0 1 2.5 0l1 1a1.8 1.8 0 0 1 0 2.5L9 18.5z" />
      <Path d="m13.8 6.7 3.5 3.5" />
    </>
  ),
  move: (
    <>
      <Path d="M3.5 12h11M11 8l4 4-4 4" />
      <Path d="M14 4.5h3.5a2 2 0 0 1 2 2v11a2 2 0 0 1-2 2H14" />
    </>
  ),
  home: (
    <>
      <Path d="M4 11 12 4.5l8 6.5" />
      <Path d="M6.5 9.5V19.5h11V9.5" />
    </>
  ),
  inbox: (
    <>
      <Path d="M4 13.5 6.5 5.5h11l2.5 8v5a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2z" />
      <Path d="M4 13.5h4.5l1.2 2.5h4.6l1.2-2.5H20" />
    </>
  ),
  photo: (
    <>
      <Rect x="3.5" y="5" width="17" height="14" rx="2" />
      <Circle cx="9" cy="10" r="1.6" />
      <Path d="m4.5 17.5 5-4.5 3.5 3 2.5-2 4 3.5" />
    </>
  ),
  box: (
    <>
      <Path d="M3.5 8 12 4l8.5 4v8.5L12 20.5l-8.5-4z" />
      <Path d="M3.5 8 12 12l8.5-4M12 12v8.5" />
    </>
  ),
  drawer: (
    <>
      <Rect x="4" y="4.5" width="16" height="15" rx="2" />
      <Path d="M4 12h16M10 8.25h4M10 15.75h4" />
    </>
  ),
  shelf: (
    <>
      <Path d="M4.5 4v16.5M19.5 4v16.5M4.5 10h15M4.5 16h15" />
      <Path d="M7.5 10V6.5h3V10M13 16v-3.5h4.5V16" />
    </>
  ),
  cabinet: (
    <>
      <Rect x="5" y="3.5" width="14" height="17" rx="1.5" />
      <Path d="M12 3.5v17M10 10.5v3M14 10.5v3" />
    </>
  ),
  bin: (
    <>
      <Path d="M3.5 5.5h17v3h-17z" />
      <Path d="m5 8.5 1 10.4a1.6 1.6 0 0 0 1.6 1.4h8.8a1.6 1.6 0 0 0 1.6-1.4L19 8.5M10 12.5h4" />
    </>
  ),
  bag: (
    <>
      <Path d="M5.5 8.5h13l-1 11.5h-11z" />
      <Path d="M9 8.5V7a3 3 0 0 1 6 0v1.5" />
    </>
  ),
  crate: (
    <>
      <Rect x="3.5" y="6" width="17" height="13" rx="1" />
      <Path d="M3.5 10.5h17M3.5 14.5h17M7.5 6v13M16.5 6v13" />
    </>
  ),
  other: (
    <>
      <Path d="M4 12.2V5a1 1 0 0 1 1-1h7.2l7.8 7.8-8.2 8.2z" />
      <Circle cx="8.5" cy="8.5" r="1.3" />
    </>
  ),

  // New glyphs in the desk's style (spec Appendix B).
  spaces: (
    <>
      <Rect x="3.5" y="4.5" width="17" height="15" rx="2" />
      <Path d="M12 4.5v5.5M12 14v5.5M3.5 12h5.5" />
    </>
  ),
  camera: (
    <>
      <Path d="M4 8.5a2 2 0 0 1 2-2h2l1.5-2h5l1.5 2h2a2 2 0 0 1 2 2V18a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2z" />
      <Circle cx="12" cy="13" r="3.5" />
    </>
  ),
  gallery: (
    <>
      <Path d="M7 3.5h11.5a2 2 0 0 1 2 2V17" />
      <Rect x="3.5" y="6.5" width="14" height="14" rx="2" />
      <Path d="m4.5 18 4-3.5 3 2.5 2-1.5 3.5 2.5" />
    </>
  ),
  scan: (
    <Path d="M4 8V6a2 2 0 0 1 2-2h2M16 4h2a2 2 0 0 1 2 2v2M20 16v2a2 2 0 0 1-2 2h-2M8 20H6a2 2 0 0 1-2-2v-2M7.5 12h9" />
  ),
  qr: (
    <>
      <Rect x="4" y="4" width="6" height="6" rx="1" />
      <Rect x="14" y="4" width="6" height="6" rx="1" />
      <Rect x="4" y="14" width="6" height="6" rx="1" />
      <Path d="M14 14h2.5v2.5M20 14v.01M17 20h3v-3M14 19.5v.5" />
    </>
  ),
  settings: (
    <>
      <Path d="M4 7h9M17 7h3M4 17h3M11 17h9" />
      <Circle cx="15" cy="7" r="2" />
      <Circle cx="9" cy="17" r="2" />
    </>
  ),
  flash: <Path d="M13 3.5 6 13.5h5.5l-1 7 7.5-10h-5.5z" />,
  flashOff: (
    <>
      <Path d="M13 3.5 9.6 8.4M7.9 10.8 6 13.5h5.5l-1 7 3.3-4.4M15.6 13.1 18 10.5h-4.6" />
      <Path d="M4 4l16 16" />
    </>
  ),
  torch: (
    <>
      <Path d="M8 3.5h8v3l-2 3.5v10.5h-4V10L8 6.5z" />
      <Path d="M8 6.5h8M12 13v2.5" />
    </>
  ),
  keyboard: (
    <>
      <Rect x="2.5" y="6" width="19" height="12" rx="2" />
      <Path d="M6.5 10h.01M10 10h.01M13.5 10h.01M17 10h.01M7.5 14h9" />
    </>
  ),
  chevronRight: <Path d="M9.5 5.5 16 12l-6.5 6.5" />,
  chevronDown: <Path d="M5.5 9.5 12 16l6.5-6.5" />,
  check: <Path d="M5 12.5l4.5 4.5L19 7.5" />,
  trash: <Path d="M4.5 6.5h15M9.5 6.5v-2h5v2M6.5 6.5l1 13h9l1-13M10 10.5v6M14 10.5v6" />,
  share: (
    <>
      <Path d="M12 3.5v11M8 7.5l4-4 4 4" />
      <Path d="M7 10.5H6A1.5 1.5 0 0 0 4.5 12v7A1.5 1.5 0 0 0 6 20.5h12a1.5 1.5 0 0 0 1.5-1.5v-7a1.5 1.5 0 0 0-1.5-1.5h-1" />
    </>
  ),
  warning: (
    <>
      <Path d="M12 4 21 19.5H3z" />
      <Path d="M12 10v4M12 17h.01" />
    </>
  ),
  info: (
    <>
      <Circle cx="12" cy="12" r="8.5" />
      <Path d="M12 11v5M12 8h.01" />
    </>
  ),
  cloudOff: (
    <>
      <Path d="M7 18.5h10a3.5 3.5 0 0 0 1-6.86 5.5 5.5 0 0 0-10.1-2.3A4.5 4.5 0 0 0 7 18.5z" />
      <Path d="M4 4l16 16" />
    </>
  ),
  server: (
    <>
      <Rect x="4" y="4.5" width="16" height="6" rx="1.5" />
      <Rect x="4" y="13.5" width="16" height="6" rx="1.5" />
      <Path d="M7.5 7.5h.01M7.5 16.5h.01" />
    </>
  ),
  phone: (
    <>
      <Rect x="7" y="3" width="10" height="18" rx="2" />
      <Path d="M11 17.5h2" />
    </>
  ),
  backup: (
    <>
      <Path d="M3.5 4.5h17v4h-17z" />
      <Path d="M5 8.5v10a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-10" />
      <Path d="M12 17v-5.5M9.5 14 12 11.5l2.5 2.5" />
    </>
  ),
  shield: <Path d="M12 3.5 19 6v5.5c0 4.2-2.9 7.7-7 9-4.1-1.3-7-4.8-7-9V6z" />,
  refresh: (
    <>
      <Path d="M19.5 12a7.5 7.5 0 1 1-2.2-5.3" />
      <Path d="M19.5 4.5v4h-4" />
    </>
  ),
  sparkle: <Path d="M12 4l1.8 5.2L19 11l-5.2 1.8L12 18l-1.8-5.2L5 11l5.2-1.8z" />,
  clock: (
    <>
      <Circle cx="12" cy="12" r="8.5" />
      <Path d="M12 7.5V12l3 2" />
    </>
  ),
  layers: (
    <>
      <Path d="M12 4 20 8.5 12 13 4 8.5z" />
      <Path d="M4 12.5 12 17l8-4.5" />
      <Path d="M4 16.5 12 21l8-4.5" />
    </>
  ),
  link: (
    <>
      <Path d="M10 14a4 4 0 0 0 5.66 0l3-3a4 4 0 0 0-5.66-5.66l-1 1" />
      <Path d="M14 10a4 4 0 0 0-5.66 0l-3 3a4 4 0 0 0 5.66 5.66l1-1" />
    </>
  ),
} satisfies Record<string, ReactElement>;

export type IconName = keyof typeof GLYPHS;

/**
 * True for a glyph name. Lets legacy call sites that still pass an emoji as an
 * `icon` keep compiling: anything that is not a glyph renders nothing.
 */
export function isIconName(value: unknown): value is IconName {
  return typeof value === 'string' && Object.prototype.hasOwnProperty.call(GLYPHS, value);
}
