import { plural, sentenceList } from '@/i18n/format';

/**
 * Single source of user-facing copy.
 *
 * The MVP ships English only, but every string is routed through here so
 * adding a locale later is a data change rather than a hunt through JSX
 * (issue #12). Keys are grouped by screen.
 *
 * Each top-level section has one owner. Foundation (F) owns the shared
 * sections at the top; each screen package (S1–S8) adds keys only inside its
 * own sections, and may change the wording of a key it owns. Renaming or
 * removing a key, or changing a function's parameters, waits for Cleanup,
 * because screens that have not moved yet may still read it.
 */
export const strings = {
  // Foundation sections (owner: F). Screen packages read these and never edit them.
  app: {
    name: 'Inventory',
  },
  common: {
    cancel: 'Cancel',
    delete: 'Delete',
    save: 'Save',
    retry: 'Retry',
    done: 'Done',
    back: 'Back',
    edit: 'Edit',
    settings: 'Settings',
    close: 'Close',
    tryAgain: 'Try again',
    dismiss: 'Dismiss',
    notNow: 'Not now',
    showMore: 'Show more',
    loading: 'Loading…',
    undo: 'Undo',
    view: 'View',
    goToHome: 'Go to Home',
    goToSpaces: 'Go to Spaces',
    goBack: 'Go back',
    findAnything: 'Find anything',
    clearSearch: 'Clear search',
  },
  tabs: {
    home: 'Home',
    spaces: 'Spaces',
    /** @deprecated The Search tab goes when Home's search lands (S1). */
    search: 'Search',
    add: 'Add',
    addA11y: 'Add an item',
    addHint: 'Long press for Quick Snap',
    quickSnapAction: 'Quick Snap',
    scan: 'Scan',
    dropZone: 'Drop zone',
    waitingA11y: (count: number) => `${count} waiting`,
  },
  boot: {
    opening: 'Opening your inventory…',
    failedTitle: 'Inventory could not be opened',
    failedBody:
      'Your data is still on this phone. Try again, and if this keeps happening, restart the app.',
  },
  a11y: {
    /** Spoken form of a container code: "label D R W, 7 K 2 M". */
    labelCode: (spelled: string) => `label ${spelled}`,
    labelCodeTitle: (spelled: string) => `Label code ${spelled}`,
    inPlace: (space: string, container: string, spelled: string) =>
      `In ${space}, ${container}, label ${spelled}`,
    inSpace: (space: string, spelled: string) => `In ${space}, label ${spelled}`,
    inDropZone: 'In the drop zone, not filed yet',
    searchHousehold: 'Search the household',
    searchHint: 'Opens Home with the keyboard ready',
    opensItem: 'Opens the item.',
    opensSpace: 'Opens the space',
    opensContainer: 'Opens the container',
    whereItIs: 'Where it is',
    loading: 'Loading…',
    dismissToast: 'Dismiss',
    availableAction: (label: string) => `${label} available`,
  },
  entities: {
    /** Shown in place of a name for items captured but not yet identified. */
    unnamedItem: 'Needs a name',
    typeNames: {
      box: 'Box',
      drawer: 'Drawer',
      shelf: 'Shelf',
      cabinet: 'Cabinet',
      bin: 'Bin',
      bag: 'Bag',
      crate: 'Crate',
      other: 'Container',
    } as Record<string, string>,
    unnamedContainer: (typeName: string) => `Unnamed ${typeName.toLowerCase()}`,
    /** Spoken names for the palette, instead of "Colour 3". */
    colourNames: {
      '#5B8DEF': 'Blue',
      '#2E9E4F': 'Green',
      '#E4572E': 'Orange',
      '#B15BEF': 'Purple',
      '#E0A800': 'Amber',
      '#0F9BB0': 'Teal',
    } as Record<string, string>,
    currentColour: 'Current colour',
    /** Spoken names for the space icons, instead of emoji descriptions. */
    iconNames: {
      '🛋️': 'Sofa',
      '🍳': 'Pan',
      '🛏️': 'Bed',
      '🚗': 'Car',
      '🧰': 'Toolbox',
      '📚': 'Books',
      '🧺': 'Basket',
      '🏠': 'House',
      '🪴': 'Plant',
      '🎒': 'Backpack',
      '👕': 'Shirt',
      '🚪': 'Door',
    } as Record<string, string>,
    currentIcon: 'Current icon',
    items: (count: number) => plural(count, 'item', 'items'),
    spaceCounts: (containers: number, items: number) =>
      sentenceList([plural(containers, 'container', 'containers'), plural(items, 'item', 'items')]),
  },
  rows: {
    itemA11y: (name: string, where: string, quantity: string) => `${name}. ${where}. ${quantity}.`,
    quantity: (count: number) => `Quantity ${count}`,
    noneLeft: 'None left',
    times: (count: number) => `×${count}`,
    added: (ago: string) => `Added ${ago}`,
    spaceA11y: (name: string, counts: string) => `${name}. ${counts}.`,
    containerA11y: (
      label: string,
      type: string,
      spelled: string,
      items: string,
      hasLabel: boolean,
    ) => `${label}, ${type}, label ${spelled}. ${items}${hasLabel ? '. Has a QR label' : ''}.`,
    qrLabel: 'QR label',
    file: 'File…',
    fileA11y: (name: string) => `File “${name}”…`,
    deleteA11y: (name: string) => `Delete “${name}”`,
    deletePhotoA11y: 'Delete this photo',
  },
  where: {
    keptIn: 'Kept in',
    dropZone: 'Drop zone',
    notFiledYet: '· not filed yet',
    notFiledNote: 'Not filed yet',
    into: 'Into the drop zone',
    sortLater: 'Sort it later',
  },
  quantity: {
    label: 'Quantity',
    howMany: 'How many',
    noneRightNow: 'None left right now',
    decrease: (name: string) => `Decrease quantity of ${name}`,
    increase: (name: string) => `Increase quantity of ${name}`,
    /** For a stepper with no item yet (the Add form). */
    decreasePlain: 'Decrease quantity',
    increasePlain: 'Increase quantity',
    field: (name: string) => `Quantity of ${name}`,
    fieldPlain: 'Quantity',
    typeNumber: 'Type a number',
    done: 'Done',
    chipA11y: (name: string, value: string) => `Quantity of ${name}, ${value}`,
    chipHint: 'Shows plus and minus buttons',
    /** The spoken value at zero, inside a longer sentence. */
    noneLeftValue: 'none left',
    notSaved: 'The quantity was not saved. Try again.',
    notSavedOffline: 'The quantity was not saved. Check the connection and try again.',
    notSavedNamed: (name: string, offline: boolean) =>
      offline
        ? `The quantity of “${name}” was not saved. Check the connection and try again.`
        : `The quantity of “${name}” was not saved. Try again.`,
    gone: 'This item is gone, so the quantity was not saved.',
  },
  picker: {
    filter: 'Type a container, space or label code',
    filterA11y: 'Find a container',
    recent: 'Recent',
    dropZone: 'Drop zone',
    sortLater: 'Sort it later',
    hereNow: 'Here now',
    hereNowA11y: (label: string) => `${label}, here now`,
    optionA11y: (label: string, space: string, spelled: string) =>
      `${label}, in ${space}, label ${spelled}`,
    newContainerIn: (space: string) => `New container in ${space}…`,
    noMatch: (query: string) => `No container matches “${query}”.`,
    none: {
      title: 'There are no containers yet',
      body: 'Make one in a space first.',
      action: 'New space…',
    },
  },
  forms: {
    optional: '(optional)',
    discardTitle: 'Discard your changes?',
    discardBody: 'What you typed will be lost.',
    keepEditing: 'Keep editing',
    discard: 'Discard',
    required: 'required',
    errorA11y: (error: string) => `error: ${error}`,
    moreDetails: 'More details',
    moreDetailsA11y: (expanded: boolean) => `More details, ${expanded ? 'expanded' : 'collapsed'}`,
    categoryLabel: 'Category',
    categoryPlaceholder: 'Tools',
    tagsLabel: 'Tags',
    tagsPlaceholder: 'winter, fragile',
    tagsHint: 'Separate tags with commas.',
    notesLabel: 'Notes',
    itemNameRequired: 'Give the item a name.',
    codeCounter: (count: number, total: number) => `${count} of ${total} characters`,
  },
  errors: {
    offline: {
      title: 'The home server did not answer',
      read: 'Check the internet connection, then try again. Nothing on this phone was lost.',
      save: 'It was not saved. Check the internet connection and try again. What you typed is still here.',
    },
    revoked: {
      title: 'This phone is no longer part of the household',
      body: 'It may have been removed on another phone. Join again to carry on.',
    },
    gone: {
      item: 'This item is gone',
      space: 'This space is not in the household any more',
      container: 'This container is not in the household any more',
      body: 'It was deleted, probably on another phone. Nothing else changed.',
    },
    /** Generic wording; screens that know the record supply their own sentence. */
    conflict: {
      title: 'This was changed on another phone',
      body: 'Someone changed it on another phone just now, so nothing was overwritten. Try again to see the latest version.',
    },
    photo: {
      title: 'The photo is missing',
      body: 'The item is fine. Only its photo could not be found on the home server.',
    },
    server: {
      title: 'Something went wrong on the home server',
      body: 'Try again in a moment. If it keeps happening, the home server may need a restart.',
    },
    local: {
      title: 'Your inventory could not be read',
      read: 'Try again. If this keeps happening, restart the app. Your data is still on this phone.',
      save: 'It was not saved. Try again.',
    },
    refreshFailed: 'This could not be refreshed. Showing what was loaded before.',
    dropZoneLocked: {
      title: 'The drop zone cannot be changed',
      body: 'It is where new items wait to be filed.',
      action: 'Go to the drop zone',
    },
  },
  connection: {
    reconnecting: 'Reconnecting to the home server… What you see may be a few minutes old.',
    retry: 'Try again',
    shared: 'Shared with the household',
    local: 'Kept on this phone',
    sharedReconnecting: 'Shared with the household · reconnecting',
    connected: 'Connected',
    reconnectingShort: 'Reconnecting…',
  },
  revoked: {
    title: 'This phone is no longer part of the household',
    body: 'It may have been removed on another phone. Join again to see the household inventory.',
    join: 'Join again',
    local: 'Use this phone on its own',
  },
  permissions: {
    cameraRationaleTitle: 'Use the camera',
    cameraRationaleBody:
      'Inventory uses the camera to photograph items and scan QR labels. Photos stay on this device.',
    captureBodyPaired:
      'Photos of items are shared with your household, not saved to your photo library.',
    captureBodyLocal: 'Photos of items stay in this app, not in your photo library.',
    scanBody: 'Point it at the label on a box and the box opens straight away.',
    cameraDeniedTitle: 'Camera access is off',
    cameraDeniedBody:
      'Camera access is off. You can turn it on in Settings, or keep adding items by typing the details.',
    offBodyCapture: 'Turn it on in Settings, or type it instead.',
    offBodyScan: 'Turn it on in Settings, or type the code instead.',
    openSettings: 'Open Settings',
    grant: 'Allow camera',
    continueManually: 'Continue without the camera',
    choosePhotoInstead: 'Choose a photo instead',
    typeItInstead: 'Type it instead',
    typeCodeInstead: 'Type a code instead',
    libraryDeniedTitle: 'Photo library unavailable',
    libraryDeniedBody:
      'Photo access is off. You can turn it on in Settings, or add the item without a photo.',
  },
  suggestions: {
    running: 'Looking at your photo… you can start typing now.',
    refreshing: 'Working out the details for your title…',
    applied: 'Suggested from your photo',
    check: 'Check the details and change anything that is wrong.',
    refreshed: (name: string) => `Details updated for “${name}”`,
    stale: (name: string) => `Title changed to “${name}”`,
    staleBody: 'The category and tags still describe our earlier guess.',
    update: 'Update the other details',
    updateHint: 'Replaces the category and tags using your title',
    failed: 'Add the details yourself',
    retry: 'Try suggestions again',
  },
  camera: {
    close: 'Close camera',
    torch: 'Torch',
    torchState: (on: boolean) => `Torch, ${on ? 'on' : 'off'}`,
    notOurs: { title: 'Not one of our labels', body: 'That code was not made by this app.' },
    scanAgain: 'Scan again',
    didNotStartScan: 'The camera did not start. Close and try again, or type the code instead.',
  },

  // owner: S1
  home: {},
  // owner: S1
  search: {
    placeholder: 'Search items, tags, or boxes',
    idle: {
      title: 'Find anything you have stored',
      body: 'Search by item name, category, tag, or a container code like BOX-7K2M.',
    },
    noResults: {
      title: 'No matches',
      body: 'Try fewer words, or check a different spelling.',
    },
    locations: 'Locations',
    itemsHeading: 'Items',
    locationMatch: 'Matched this location',
  },

  // owner: S2
  spaces: {
    title: 'Spaces',
    empty: {
      title: 'Start with a space',
      body: 'A space is a room or broad area where you keep things — a garage, a loft, a kitchen.',
      action: 'Create your first space',
    },
    create: 'New space',
    quickAddLabel: 'Quick add',
    customLabel: 'Custom space name',
    customAction: 'Create custom space',
    presetHint: (name: string) => `Create ${name} straight away`,
    nameLabel: 'Name',
    namePlaceholder: 'Enter a custom name',
    nameRequired: 'Give the space a name.',
    iconLabel: 'Icon',
    colorLabel: 'Colour',
    itemCount: (items: number) => `${items} item${items === 1 ? '' : 's'}`,
    deleteTitle: 'Delete this space?',
    counts: (containers: number, items: number) =>
      `${containers} container${containers === 1 ? '' : 's'} · ${items} item${
        items === 1 ? '' : 's'
      }`,
  },
  // owner: S2
  spaceForm: {
    /** Header title, read by the root layout. */
    newTitle: 'New space',
    /** Header title, read by the root layout. */
    editTitle: 'Edit space',
  },
  // owner: S2
  containerForm: {
    /** Header title, read by the root layout. */
    newTitle: 'New container',
    /** Header title, read by the root layout. */
    editTitle: 'Edit container',
  },

  // owner: S3
  container: {},
  // owner: S3
  qr: {},
  // owner: S3
  link: {},

  // owner: S4
  item: {},
  // owner: S4
  editItem: {
    /** Header title, read by the root layout. */
    title: 'Edit details',
  },
  // owner: S4
  move: {},
  // owner: S4
  photo: {},

  // owner: S5
  add: {
    /** Header title, read by the root layout. */
    title: 'Add an item',
  },

  // owner: S6
  dropZone: {
    title: 'Drop zone',
    tagline: 'Snap now, sort later',
    quickSnap: 'Quick Snap',
    capture: 'Add items',
    fileAction: 'Choose a container',
    intro: 'These are waiting for a home. Tap one to file it.',
    count: (count: number) => `${count} item${count === 1 ? '' : 's'} waiting`,
    moveIntro: (name: string) => `Where does “${name}” belong?`,
    empty: {
      title: 'Nothing waiting',
      body: 'Photograph things as you find them and they land here, ready to file whenever you like.',
    },
    noContainers: {
      title: 'No containers yet',
      body: 'Create a space and a container first, then you can file what you have captured.',
    },
  },
  // owner: S6
  capture: {
    modeLabel: 'Capture mode',
    modeSingle: 'Single',
    modeFast: 'Fast',
    singleHint: 'Tap to focus, then fill the frame',
    tapToFocus: 'Focus camera',
    fastHint: 'Keep shooting — details fill in by themselves',
    fastBadge: '⚡ Fast mode',
    saving: 'Saving your photo…',
    done: 'Done',
    doneCount: (count: number) => `Done · ${count}`,
    identified: (count: number) => `✓ ${count} item${count === 1 ? '' : 's'} identified`,
    identifying: (count: number) => `Identifying ${count}…`,
    /** Some came back named, some did not — report both rather than the total. */
    identifiedPartly: (identified: number, unnamed: number) =>
      `✓ ${identified} identified · ${unnamed} to name`,
    /** Recognition gave us nothing; the photos are still safely saved. */
    savedUnnamed: (count: number) => `✓ ${count} saved · name ${count === 1 ? 'it' : 'them'} later`,
    failedSome: (count: number) =>
      `${count} photo${count === 1 ? '' : 's'} could not be saved. Nothing else was lost.`,
    review: {
      summary: (count: number) => `${count} item${count === 1 ? '' : 's'} captured`,
      pending: (count: number) => `Saving ${count} more…`,
      toName: (count: number) =>
        count === 1 ? '1 still needs a name' : `${count} still need a name`,
      keepAll: (count: number) => (count === 1 ? 'Keep this item' : `Keep all ${count}`),
      keepShooting: 'Keep shooting',
      empty: {
        title: 'Nothing was saved',
        body: 'None of the photos from this session could be saved. Head back and try again.',
      },
    },
  },
  // owner: S6
  review: {},

  // owner: S7
  scan: {
    title: 'Scan a QR label',
    hint: 'Point the camera at a label on one of your containers.',
    unknownTitle: 'New label',
    unknownBody: 'This label is not linked yet. Choose the container it belongs to.',
    invalidTitle: 'Not an Inventory label',
    invalidBody: 'That code was not created by this app.',
    rebindTitle: 'Move this label?',
    scanAgain: 'Scan again',
  },
  // owner: S7
  deepLink: {
    /** Header title, read by the root layout. */
    title: 'QR label',
  },

  // owner: S8
  settings: {
    /** Header title, read by the root layout. */
    title: 'Settings',
  },
  // owner: S8
  household: {
    title: 'Home server',
    settingsLabel: 'Home server',
    disconnected: 'This phone',
    connected: 'Connected',
    connectedAs: (name: string) => `Paired as ${name}`,
    originHint: 'Uses https://inventory.wystudio.be',
    secretLabel: 'Bootstrap secret',
    secretPlaceholder: 'MMWKY-M2H78-…',
    secretHint: 'Printed once in the server logs when the household was created.',
    deviceNameLabel: 'Name for this phone',
    pair: 'Pair this phone',
    pairing: 'Pairing…',
    disconnect: 'Stop using the home server',
    body: 'Pairing makes this phone read and write the household inventory on the home server. Your local copy stays on the phone until you import it.',
    error: 'Could not pair. Check the secret and that the server is reachable.',
    offline: 'The home server could not be reached. Try again when you are online.',
    conflict:
      'Someone else changed this item. Open it again to see the latest version, then retry.',
    importLabel: 'Import this phone’s inventory',
    importing: 'Importing…',
    importTitle: 'Copy this phone onto the home server?',
    importBody:
      'Spaces, containers, items, and photos on this phone become the household inventory. Photos go to the existing cloud bucket, not the home server disk.',
    importDone: (items: number, photos: number) =>
      `Imported ${items} item${items === 1 ? '' : 's'} and ${photos} photo${photos === 1 ? '' : 's'}.`,
    /** Header title, read by the root layout. */
    screenTitle: 'Household',
  },
  // owner: S8
  join: {},
  // owner: S8
  backup: {
    /** Header title, read by the root layout. */
    title: 'Backup',
  },
  // owner: S8
  privacy: {
    /** Header title, read by the root layout. */
    title: 'Privacy',
  },
  // owner: S8
  onboarding: {
    skip: 'Skip',
    next: 'Next',
    start: 'Get started',
    steps: [
      {
        icon: '📸',
        title: 'Capture',
        body: 'Photograph an item as you put it away. Suggestions fill in the details, and you can always type them yourself.',
      },
      {
        icon: '📦',
        title: 'Store',
        body: 'Group items into containers, and containers into spaces like a garage or a loft. Stick a QR label on a box to open it instantly later.',
      },
      {
        icon: '🔎',
        title: 'Find',
        body: 'Search what you remember. Results show the exact space and container an item is in — and it all works offline.',
      },
    ],
  },

  // Legacy sections: read-only for every package, removed by Cleanup.
  items: {
    empty: {
      title: 'Nothing in here yet',
      body: 'Add the first item with a photo, or type the details yourself.',
      photoAction: 'Take a photo',
      manualAction: 'Add without a photo',
    },
    nameLabel: 'Name',
    namePlaceholder: 'Cordless drill',
    nameRequired: 'Give the item a name.',
    /** Shown in place of a title for items captured but not yet identified. */
    unnamed: 'Needs a name',
    categoryLabel: 'Category',
    tagsLabel: 'Tags',
    tagsHint: 'Separate tags with commas.',
    quantityLabel: 'Quantity',
    quantityInvalid: 'Quantity must be a whole number of 0 or more.',
    quantityDecrease: 'Decrease quantity',
    quantityIncrease: 'Increase quantity',
    quantityA11y: (count: number) => `Quantity ${count}`,
    quantitySaveFailed: 'Quantity could not be saved.',
    notesLabel: 'Notes',
    save: 'Save item',
    saveAndAdd: 'Save and add another',
    deleteTitle: 'Delete this item?',
    deleteBody: 'This removes the item and its photo from this device.',
  },
  containers: {
    empty: {
      title: 'Add a container',
      body: 'Containers are the boxes, drawers, and shelves inside this space.',
      action: 'Add a container',
    },
    create: 'New container',
    createAction: 'Create container',
    typeNames: {
      box: 'Box',
      drawer: 'Drawer',
      shelf: 'Shelf',
      cabinet: 'Cabinet',
      bin: 'Bin',
      bag: 'Bag',
      crate: 'Crate',
      other: 'Other',
    } as Record<string, string>,
    nameLabel: 'Name (optional)',
    namePlaceholder: 'Winter clothes',
    typeLabel: 'Type',
    spaceLabel: 'Space',
    deleteTitle: 'Delete this container?',
    qrBound: 'QR label attached',
    qrUnbound: 'No QR label',
  },
} as const;
