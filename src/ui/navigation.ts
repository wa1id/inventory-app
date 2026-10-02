import { router } from 'expo-router';

import { DROP_ZONE_CONTAINER_ID, DROP_ZONE_SPACE_ID } from '@/db/constants';
import type { ContainerVisualType } from '@/db/types';
import type { StoredImage } from '@/services/capture/imageStore';
import { requestSearchFocus } from '@/ui/searchFocus';

export type TabHref = '/' | '/spaces' | '/scan' | '/drop-zone';

/**
 * Goes to a tab without ever stacking a second tab shell.
 *
 * From a pushed screen or a modal, pushing or navigating to a tab path pushes
 * another `(tabs)` with its own tab bar, so the stack is popped back to the
 * existing one instead. At a tab root there is nothing to pop and `POP_TO` is
 * not handled by the tab router, so it navigates within the tabs.
 */
export function goToTab(href: TabHref): void {
  if (router.canDismiss()) router.dismissTo(href);
  else router.navigate(href);
}

/**
 * Opens a container. The drop zone is a real container row, but its screen is
 * the Drop zone tab: nothing ever navigates to `/container/drop-zone`.
 */
export function openContainer(containerId: string): void {
  if (containerId === DROP_ZONE_CONTAINER_ID) goToTab('/drop-zone');
  else router.push(`/container/${containerId}`);
}

/** Opens a space; the drop zone's system space is the Drop zone tab too. */
export function openSpace(spaceId: string): void {
  if (spaceId === DROP_ZONE_SPACE_ID) goToTab('/drop-zone');
  else router.push(`/space/${spaceId}`);
}

/**
 * The search buttons on Spaces, Drop zone and detail headers: Home with the
 * keyboard up. The request is a one-shot flag rather than a route param, so it
 * cannot stick to Home and raise the keyboard again later.
 */
export function focusSearch(): void {
  requestSearchFocus({ afterTransition: router.canDismiss() });
  goToTab('/');
}

/**
 * Quick Snap: fast capture straight into the drop zone (Add's long press,
 * Home's drop-zone card, the Drop zone tab).
 */
export function openQuickSnap(): void {
  router.push(`/capture?containerId=${DROP_ZONE_CONTAINER_ID}&mode=fast`);
}

/*
 * What routes opened with a `request` param deliver through `routeResult`.
 * Producers and consumers live in different packages, so the shapes are
 * fixed here.
 */

/** `/item/[id]/move?request=`: the item moved (or filed) from one container to another. */
export interface MoveResult {
  itemId: string;
  from: string;
  to: string;
  /** The item's `updatedAt` after the move, for an Undo that does not conflict with itself. */
  updatedAt: number;
  /**
   * A filing run only: the drop zone's ids as read right after the move, so
   * the run's next item agrees with the toast. Absent when that read failed.
   */
  waiting?: string[];
}

/**
 * `/container/new?spaceId&request=`: the container just created, with what
 * the place picker shows of it, so the picker need not read it back.
 */
export interface NewContainerResult {
  containerId: string;
  name: string | null;
  shortCode: string;
  visualType: ContainerVisualType;
  spaceId: string;
}

/** `/space/new?request=`: the space just created. */
export interface NewSpaceResult {
  spaceId: string;
  name: string;
}

/** `/capture?…&request=`: the photo taken in single mode, already stored. */
export type PhotoResult = StoredImage;
