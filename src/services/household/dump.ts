/**
 * Id-preserving household snapshot used by import (K12, K16).
 *
 * Live writes assign server ids. Import is the one path that keeps the phone's
 * ids, so two devices and the box agree on what a row is.
 */
export interface HouseholdDump {
  spaces: DumpSpace[];
  containers: DumpContainer[];
  items: DumpItem[];
  tags: DumpTag[];
  itemTags: DumpItemTag[];
  qrBindings: DumpQrBinding[];
  photos: DumpPhoto[];
}

export interface DumpSpace {
  id: string;
  name: string;
  icon: string;
  color: string;
  kind: string;
  createdAt: number;
  updatedAt: number;
}

export interface DumpContainer {
  id: string;
  spaceId: string;
  name: string | null;
  visualType: string;
  shortCode: string;
  kind: string;
  createdAt: number;
  updatedAt: number;
}

export interface DumpItem {
  id: string;
  containerId: string;
  name: string;
  category: string | null;
  quantity: number;
  notes: string | null;
  searchText: string;
  createdAt: number;
  updatedAt: number;
}

export interface DumpTag {
  id: string;
  name: string;
  normalizedName: string;
  createdAt: number;
}

export interface DumpItemTag {
  itemId: string;
  tagId: string;
}

export interface DumpQrBinding {
  id: string;
  token: string;
  containerId: string;
  createdAt: number;
  updatedAt: number;
}

export interface DumpPhoto {
  id: string;
  itemId: string;
  width: number | null;
  height: number | null;
  byteSize: number | null;
  createdAt: number;
}

export function emptyDump(): HouseholdDump {
  return {
    spaces: [],
    containers: [],
    items: [],
    tags: [],
    itemTags: [],
    qrBindings: [],
    photos: [],
  };
}
