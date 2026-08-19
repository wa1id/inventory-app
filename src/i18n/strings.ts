/**
 * Single source of user-facing copy.
 *
 * The MVP ships English only, but every string is routed through here so
 * adding a locale later is a data change rather than a hunt through JSX
 * (issue #12). Keys are grouped by screen.
 */
export const strings = {
  app: {
    name: 'Inventory',
  },
  tabs: {
    spaces: 'Spaces',
    search: 'Search',
    scan: 'Scan',
  },
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
    quantityInvalid: 'Quantity must be a whole number of at least 1.',
    notesLabel: 'Notes',
    save: 'Save item',
    saveAndAdd: 'Save and add another',
    deleteTitle: 'Delete this item?',
    deleteBody: 'This removes the item and its photo from this device.',
  },
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
  capture: {
    modeLabel: 'Capture mode',
    modeSingle: 'Single',
    modeFast: 'Fast',
    singleHint: 'Fill the frame with the item',
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
  permissions: {
    cameraRationaleTitle: 'Camera access',
    cameraRationaleBody:
      'Inventory uses the camera to photograph items and scan QR labels. Photos stay on this device.',
    cameraDeniedTitle: 'Camera unavailable',
    cameraDeniedBody:
      'Camera access is off. You can turn it on in Settings, or keep adding items by typing the details.',
    openSettings: 'Open settings',
    grant: 'Allow camera',
    continueManually: 'Continue without the camera',
    libraryDeniedTitle: 'Photo library unavailable',
    libraryDeniedBody:
      'Photo access is off. You can turn it on in Settings, or add the item without a photo.',
  },
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
  },
} as const;
