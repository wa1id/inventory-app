import { router } from 'expo-router';

import { DROP_ZONE_CONTAINER_ID, DROP_ZONE_SPACE_ID } from '@/db/constants';
import type { StoredImage } from '@/services/capture/imageStore';
import { requestSearchFocus } from '@/ui/searchFocus';

export type TabHref = '/' | '/spaces' | '/scan' | '/drop-zone';

/**
 * Goes to a tab without ever stacking a second tab shell.
 *
 * From a pushed screen or a modal, pushing or navigating to a tab path pushes
 * another `(tabs)` with its own tab bar, so the stack is popped back to the
 * existing one instead. At a tab root there is nothing to pop and `POP_TO` is
 * not handled by the tab router, so it navigates within the tabs (spec §2.5).
 */
export function goToTab(href: TabHref): void {
  if (router.canDismiss()) router.dismissTo(href);
  else router.navigate(href);
}

/**
 * Opens a container. The drop zone is a real container row, but its screen is
 * the Drop zone tab: nothing ever navigates to `/container/drop-zone` (B4).
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
}

/** `/container/new?spaceId&request=`: the container just created. */
export interface NewContainerResult {
  containerId: string;
}

/** `/capture?…&request=`: the photo taken in single mode, already stored. */
export type PhotoResult = StoredImage;
