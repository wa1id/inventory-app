import { plural, sentenceList } from '@/i18n/format';

/**
 * Single source of user-facing copy.
 *
 * The MVP ships English only, but every string is routed through here so
 * adding a locale later is a data change rather than a hunt through JSX
 * (issue #12). Keys are grouped by screen.
 */
export const strings = {
  // Shared sections, used across screens.
  common: {
    cancel: 'Cancel',
    delete: 'Delete',
    close: 'Close',
    tryAgain: 'Try again',
    dismiss: 'Dismiss',
    notNow: 'Not now',
    showMore: 'Show more',
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
    /** What a container holds, in words rather than "0 items". */
    contents: (count: number) => (count === 0 ? 'Empty' : plural(count, 'item', 'items')),
    /** No row of zeros for an empty place: "No containers yet", "2 containers, all empty". */
    spaceCounts: (containers: number, items: number) =>
      containers === 0
        ? 'No containers yet'
        : items === 0
          ? `${plural(containers, 'container', 'containers')}, ${containers === 1 ? 'empty' : 'all empty'}`
          : sentenceList([
              plural(containers, 'container', 'containers'),
              plural(items, 'item', 'items'),
            ]),
  },
  rows: {
    itemA11y: (name: string, where: string, quantity: string) => `${name}. ${where}. ${quantity}.`,
    quantity: (count: number) => `Quantity ${count}`,
    noneLeft: 'None left',
    times: (count: number) => `×${count}`,
    added: (ago: string) => `Added ${ago}`,
    /** On lists of new additions only (Drop zone, Review), where "Added" goes without saying. */
    addedShort: (ago: string) => ago.charAt(0).toUpperCase() + ago.slice(1),
    /** Between a quantity folded into a row's second line and the rest of it. */
    separator: ' · ',
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
    /** No-break spaces: a wrapped line never starts or ends with the dot. */
    notFiledYet: '\u00A0·\u00A0not filed yet',
    notFiledNote: 'Not filed yet',
  },
  quantity: {
    label: 'Quantity',
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
    filter: 'Container, space or code',
    filterA11y: 'Find a container',
    recent: 'Recent',
    dropZone: 'Drop zone',
    sortLater: 'Sort it later',
    hereNow: 'Here now',
    hereNowA11y: (label: string) => `${label}, here now`,
    optionA11y: (label: string, space: string, spelled: string) =>
      `${label}, in ${space}, label ${spelled}`,
    newContainerIn: (space: string) => `New container in ${space}…`,
    /** Over the "New container in …" rows when nothing matches the filter. */
    newContainerTitle: 'Make a new container',
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
    quantityInvalid: 'Quantity must be a whole number of 0 or more.',
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
    captureBodyPaired:
      'Photos of items are shared with your household, not saved to your photo library.',
    captureBodyLocal: 'Photos of items stay in this app, not in your photo library.',
    scanBody: 'Point it at the label on a box and the box opens straight away.',
    cameraDeniedTitle: 'Camera access is off',
    offBodyCapture: 'Turn it on in Settings, or type it instead.',
    offBodyScan: 'Turn it on in Settings, or type the code instead.',
    openSettings: 'Open Settings',
    grant: 'Allow camera',
    choosePhotoInstead: 'Choose a photo instead',
    typeItInstead: 'Type it instead',
    typeCodeInstead: 'Type a code instead',
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
    /** Under `failed`, which already says what to do: only why there is no suggestion. */
    failedBody: {
      not_configured: 'Photo suggestions are not set up on this phone.',
      offline: 'There is no connection, so there are no suggestions.',
      timeout: 'The suggestion took too long.',
      rate_limited: 'Too many photos were sent for suggestions just now. Try again in a moment.',
      server_error: 'Suggestions are not available right now.',
      malformed_response: 'The suggestion could not be read.',
      unsupported_version: 'This version of the app cannot read suggestions. Update the app.',
      low_confidence: 'The photo was not clear enough for a guess.',
      unrecognized: 'The item in the photo could not be recognised.',
    },
    retry: 'Try suggestions again',
  },
  camera: {
    close: 'Close camera',
    torchState: (on: boolean) => `Torch, ${on ? 'on' : 'off'}`,
    notOurs: { title: 'Not one of our labels', body: 'That code was not made by this app.' },
    scanAgain: 'Scan again',
    didNotStartScan: 'The camera did not start. Close and try again, or type the code instead.',
  },

  home: {
    title: 'Home',
    settings: 'Settings',
    summary: (spaces: number, containers: number, items: number) =>
      `${sentenceList([
        plural(spaces, 'space', 'spaces'),
        plural(containers, 'container', 'containers'),
        plural(items, 'item', 'items'),
      ])}.`,
    searchPlaceholder: 'Find anything',
    unpaired: {
      title: 'This phone keeps its own inventory.',
      body: 'Join your household to share one inventory with everyone at home.',
      join: 'Join your household',
      /** "Not now" alone does not say it keeps the notice away on this phone. */
      notNowHint: 'Hides this notice on this phone',
    },
    dropZone: {
      title: (count: number) =>
        count === 1
          ? '1 item is waiting in the drop zone'
          : `${count} items are waiting in the drop zone`,
      body: 'Give them a home when you have a moment.',
      sort: 'Sort the drop zone',
      quickSnap: 'Quick Snap',
    },
    recent: 'Recently added',
    /** In place of the list while the connection banner explains the outage and offers "Try again". */
    waitingForServer: 'Your household’s things show here as soon as the home server answers.',
    /** The "Show more" button under Recently added, named for screen readers. */
    recentMoreA11y: 'Show more recently added items',
    empty: {
      unpaired: {
        title: 'Nothing is stored here yet',
        body: 'Join your household to see what is already stored, or start this phone’s own inventory with a space.',
        join: 'Join your household',
        start: 'Start with a space',
      },
      paired: {
        /** The household's own name, or "Home" when it has none. */
        titleIn: (household: string) => `Nothing is stored in ${household} yet`,
        body: 'Items added on any phone in the household show up here.',
        add: 'Add an item',
      },
      /** Not joined, spaces made, no items yet: the next step is an item, not a space. */
      local: {
        title: 'Nothing is stored here yet',
        body: 'Add the first item. It can wait in the drop zone until you choose its place.',
        add: 'Add an item',
      },
    },
  },
  search: {
    summary: (items: number, places: number) =>
      items + places === 0
        ? 'Nothing found'
        : `${sentenceList(
            [
              items ? plural(items, 'item', 'items') : '',
              places ? plural(places, 'place', 'places') : '',
            ].filter(Boolean),
          )} found`,
    items: 'Items',
    places: 'Spaces and containers',
    keptInThose: 'Kept in those places',
    total: (name: string, count: number, places: number) =>
      `“${name}”: ×${count} in ${places} places`,
    totalNone: (name: string, places: number) => `“${name}”: none left in any of ${places} places`,
    /** The total line drawn in parts, so the count can be set apart: “AA batteries”: ×14 in 2 places. */
    totalName: (name: string) => `“${name}”:`,
    totalIn: (places: number) => `in ${places} places`,
    totalNoneIn: (places: number) => `in any of ${places} places`,
    none: {
      title: (query: string) => `Nothing called “${query}”`,
      body: 'Try fewer letters, the name of a space or container, or the code written on a box label, like BOX-7K2M.',
      add: (query: string) => `Add “${query}”…`,
    },
    failed: 'The search did not finish',
  },

  spaces: {
    title: 'Spaces',
    count: (spaces: number) => plural(spaces, 'space', 'spaces'),
    newSpace: 'New space',
    start: {
      title: 'Start with a space',
      body: 'A space is a room or area where you keep things, like a garage, a loft or a kitchen.',
      action: 'Create your first space',
      join: 'Join your household instead',
    },
    edit: (name: string) => `Edit ${name}`,
    newContainer: 'New container',
    noContainers: {
      title: (name: string) => `No containers in ${name} yet`,
      body: 'Containers are the boxes, drawers and shelves in this space. Add the first one, then put items in it.',
      action: 'Add a container',
    },
  },
  spaceForm: {
    /** Header title, read by the root layout. */
    newTitle: 'New space',
    /** Header title, read by the root layout. */
    editTitle: 'Edit space',
    quickAdd: 'Quick add',
    yourOwn: 'Your own',
    alreadyAdded: 'Already added',
    presetA11y: (name: string) => `${name}. Creates the space straight away.`,
    presetAddedA11y: (name: string) => `${name}. Already added.`,
    nameLabel: 'Name',
    namePlaceholder: 'For example, Kitchen',
    nameRequired: 'Give the space a name.',
    /** The preview row's name until one is typed. */
    previewName: 'Kitchen',
    /** Over the preview row, so it is not taken for a list row or a field. */
    previewLabel: 'On the Spaces tab it looks like this',
    /** The preview row's second line for a space not made yet. */
    previewNew: 'New space',
    iconLabel: 'Icon',
    colourLabel: 'Colour',
    create: 'Create space',
    save: 'Save changes',
    delete: 'Delete space…',
    deleteHint: 'Asks first, and says what else would be deleted.',
    deleteTitle: (name: string) => `Delete ${name}?`,
    deleteBody: (containers: number, items: number, labels: number) =>
      `This also deletes ${sentenceList([
        plural(containers, 'container', 'containers'),
        plural(items, 'item', 'items'),
      ])}${labels ? `, and unlinks ${plural(labels, 'QR label', 'QR labels')}` : ''}. This cannot be undone.`,
    deleteEmpty: 'This space is empty.',
    deleted: (name: string) => `${name} was deleted.`,
    /** The delete found nothing to delete: another phone got there first. */
    alreadyDeleted: (name: string) => `${name} was already deleted, probably on another phone.`,
    deleteFailed: (name: string, offline: boolean) =>
      offline
        ? `${name} was not deleted. Check the connection and try again.`
        : `${name} was not deleted. Try again.`,
    /** Toast after Save changes closes the sheet, as Edit details says it. */
    saved: 'Changes saved.',
    /** Toasts for a save that ended after the sheet was closed (header Cancel mid-save). */
    created: (name: string) => `${name} was added.`,
    notCreated: (name: string, offline: boolean) =>
      offline
        ? `${name} was not added. Check the connection and try again.`
        : `${name} was not added. Try again.`,
    notSaved: (name: string, offline: boolean) =>
      offline
        ? `Changes to ${name} were not saved. Check the connection and try again.`
        : `Changes to ${name} were not saved. Try again.`,
  },
  containerForm: {
    /** Header title, read by the root layout. */
    newTitle: 'New container',
    /** Header title, read by the root layout. */
    editTitle: 'Edit container',
    inSpace: (space: string) => `In ${space}`,
    typeLabel: 'Type',
    nameLabel: 'Name',
    namePlaceholder: 'Winter clothes',
    nameHint: 'Leave it empty and the container goes by its label code.',
    spaceLabel: 'Space',
    /** Read out for the code note under the name, with the code spelled. */
    codeStays: (code: string) =>
      `The label code stays ${code}, because it is printed on the label.`,
    /** Beside the code's tape under the name. */
    codeNote: 'On the label, so it never changes.',
    create: 'Create container',
    save: 'Save changes',
    delete: 'Delete container…',
    deleteHint: 'Asks first, and says what else would be deleted.',
    deleteTitle: (label: string) => `Delete ${label}?`,
    deleteBody: (items: number, hasLabel: boolean) =>
      `This also deletes ${plural(items, 'item', 'items')}${hasLabel ? ' and unlinks its QR label' : ''}. This cannot be undone.`,
    deleteEmpty: (hasLabel: boolean) =>
      `This container is empty.${hasLabel ? ' Its QR label will be unlinked.' : ''}`,
    deleted: (label: string) => `${label} was deleted.`,
    /** The delete found nothing to delete: another phone got there first. */
    alreadyDeleted: (label: string) => `${label} was already deleted, probably on another phone.`,
    deleteFailed: (label: string, offline: boolean) =>
      offline
        ? `${label} was not deleted. Check the connection and try again.`
        : `${label} was not deleted. Try again.`,
    /** Toast after Save changes closes the sheet, as Edit details says it. */
    saved: 'Changes saved.',
    /** Toasts for a save that ended after the sheet was closed (header Cancel mid-save). */
    created: (label: string) => `${label} was added.`,
    notCreated: (offline: boolean) =>
      offline
        ? 'The container was not added. Check the connection and try again.'
        : 'The container was not added. Try again.',
    notSaved: (label: string, offline: boolean) =>
      offline
        ? `Changes to ${label} were not saved. Check the connection and try again.`
        : `Changes to ${label} were not saved. Try again.`,
  },

  container: {
    edit: (label: string) => `Edit ${label}`,
    crumbA11y: (space: string) => `In ${space}. Opens the space.`,
    /** Under the title; the space is the crumb above it, so it is not said again. */
    sub: (type: string, items: number) => `${type} · ${plural(items, 'item', 'items')}`,
    qrLinked: 'QR label',
    qrLinkedA11y: 'QR label, linked. Opens the label.',
    qrNone: 'Add a QR label',
    inHere: 'In here',
    addHere: 'Add here',
    takePhotoA11y: 'Take a photo of a new item',
    takePhoto: 'Take a photo',
    empty: {
      title: (type: string) => `This ${type.toLowerCase()} is empty`,
      body: 'Add the first item with a photo, or type its name.',
    },
  },
  qr: {
    title: 'QR label',
    cardA11y: (label: string, spelled: string) => `QR label for ${label}, label ${spelled}`,
    hint: 'Print this and stick it on the container. Scanning it with this app, or with the phone’s camera, opens the container straight away.',
    share: 'Share label…',
    shareMessage: (label: string, code: string) => `${label} (${code})`,
    shareFailed: 'The label could not be shared. Try again.',
    problems: 'If the sticker is lost or damaged',
    replace: 'Replace label…',
    replaceTitle: 'Replace this label?',
    replaceBody:
      'The current sticker will stop opening this container. Only do this if the label is lost or damaged.',
    replaceConfirm: 'Replace',
    remove: 'Remove label…',
    removeTitle: 'Remove this label?',
    removeBody:
      'The container and everything in it stay exactly as they are. The sticker just stops opening it.',
    removeConfirm: 'Remove',
    made: 'New label made. Print it and replace the old sticker.',
    removed: 'Label removed.',
    none: {
      /** Names the container: the screen shows neither its name nor its code otherwise. */
      title: (label: string) => `No QR label on ${label} yet`,
      body: 'Make a label to print, or link a sticker you already printed.',
    },
    make: 'Make a QR label',
    link: 'Link a printed sticker',
    /** Failures say what still holds: an old sticker keeps working until a change succeeds. */
    makeFailed: (offline: boolean) =>
      offline
        ? 'The label was not made. Check the connection and try again.'
        : 'The label was not made. Try again.',
    replaceFailed: (offline: boolean) =>
      offline
        ? 'The label was not replaced, so the old sticker still works. Check the connection and try again.'
        : 'The label was not replaced, so the old sticker still works. Try again.',
    removeFailed: (offline: boolean) =>
      offline
        ? 'The label was not removed, so the sticker still opens this container. Check the connection and try again.'
        : 'The label was not removed, so the sticker still opens this container. Try again.',
    containerGone: 'This container is not in the household any more. Nothing else changed.',
    /** "Make" found a label after all (just linked, or made on another phone). */
    alreadyLabelled: 'This container already has a label, so no new one was made.',
  },
  link: {
    title: (label: string) => `Scan the sticker for ${label}`,
    /** Until the container has loaded. */
    titlePlain: 'Scan the sticker',
    replaceTitle: (label: string) => `Replace the label on ${label}?`,
    replaceBody: (label: string) =>
      `${label} already has a label. Its old sticker will stop opening it.`,
    replace: 'Replace',
    moveTitle: (label: string) => `Move this sticker to ${label}?`,
    moveBody: (from: string, to: string) =>
      `It opens ${from} now. After this it opens ${to} instead.`,
    move: 'Move sticker',
    linked: (label: string) => `Sticker linked to ${label}.`,
    already: (label: string) => `This sticker already opens ${label}.`,
    checking: 'Reading the sticker…',
    linking: 'Linking the sticker…',
    /** The camera was closed before a link that then did not happen. */
    notLinked: (label: string) => `The sticker was not linked to ${label}. Try again.`,
  },

  item: {
    photoA11y: (name: string) => `Photo of ${name}. Opens it full screen.`,
    photoA11yUnnamed: 'Photo of this item. Opens it full screen.',
    nameIt: {
      label: 'What is it?',
      a11y: 'Name',
      placeholder: 'Give it a name',
      save: 'Save name',
      failed: 'The name was not saved. Try again.',
      failedOffline: 'The name was not saved. Check the connection and try again.',
      /**
       * A name arrived while one was being typed (recognition, or another
       * phone; which is not known, so neither is claimed).
       */
      justNamed: (name: string) => `It was just named “${name}”.`,
      /** Saving met that name: nothing was written, and saving again keeps the typed one. */
      namedMeanwhile: (name: string) =>
        `It was just named “${name}”. Save name again to keep yours.`,
      useName: (name: string) => `Use “${name}”`,
    },
    move: 'Move…',
    moveA11y: (name: string) => `Move “${name}”…`,
    moveA11yUnnamed: 'Move this item…',
    fileIt: 'File it…',
    fileItA11y: (name: string) => `File “${name}”…`,
    fileItA11yUnnamed: 'File this item…',
    editDetails: 'Edit details',
    editDetailsA11y: (name: string) => `Edit details of “${name}”`,
    stampAdded: (date: string) => `Added ${date}.`,
    stampChanged: (ago: string) => `Last changed ${ago}.`,
    delete: 'Delete item…',
    deleteA11y: (name: string) => `Delete “${name}”…`,
    deleteTitle: (name: string) => `Delete “${name}”?`,
    deleteTitleUnnamed: 'Delete this item?',
    deleteBodyPaired:
      'This removes it and its photo from the household, on every phone. This cannot be undone.',
    deleteBodyLocal: 'This removes it and its photo from this phone. This cannot be undone.',
    deleted: (name: string) => `“${name}” was deleted.`,
    deletedUnnamed: 'The item was deleted.',
    alreadyDeleted: (name: string) => `“${name}” was already deleted, probably on another phone.`,
    alreadyDeletedUnnamed: 'The item was already deleted, probably on another phone.',
    deleteFailed: (offline: boolean) =>
      offline
        ? 'The item was not deleted. Check the connection and try again.'
        : 'The item was not deleted. Try again.',
    /** How many wait in a filing run, this item included; it counts down as the run goes. */
    progress: (waiting: number) => (waiting === 1 ? 'Last one waiting' : `${waiting} waiting`),
  },
  editItem: {
    /** Header title, read by the root layout. */
    title: 'Edit details',
    nameLabel: 'Name',
    save: 'Save changes',
    saved: 'Changes saved.',
    conflict:
      'Someone changed this item on another device while you were editing. Their changes are filled in below. Save again to keep yours as well, or cancel to keep only theirs.',
    notSaved: 'The changes were not saved. They are still here, so try again.',
  },
  move: {
    titleMove: (name: string) => `Move “${name}”`,
    titleFile: (name: string) => `File “${name}”`,
    titleMoveUnnamed: 'Move this item',
    titleFileUnnamed: 'File this item',
    movedTo: (container: string, space: string) => `Moved to ${container} (${space}).`,
    filedIn: (container: string, space: string) => `Filed in ${container} (${space}).`,
    /** The last one of a filing run: the run ends on the Drop zone tab. */
    filedLast: (container: string, space: string) =>
      `Filed in ${container} (${space}). Everything is filed.`,
    undoA11y: (name: string) => `Undo moving ${name}`,
    undoA11yUnnamed: 'Undo moving this item',
    undone: 'Move undone.',
    alreadyMoved: (container: string) =>
      `Someone already moved it to ${container} on another device.`,
    alreadyMovedToDropZone: 'Someone already moved it to the drop zone on another device.',
    failed: 'It was not moved. Check the connection and try again.',
    failedOther: 'It was not moved. Try again.',
    gone: 'This item is gone. It was deleted, probably on another phone.',
    undoGone: 'It could not be undone, because the item was deleted.',
    undoConflict: 'It could not be undone, because the item changed again since.',
    undoFailed: 'It could not be undone. Check the connection and try again.',
    undoFailedOther: 'It could not be undone. Try again.',
  },
  photo: {
    close: 'Close photo',
    a11y: (name: string) => `Photo of ${name}`,
    a11yUnnamed: 'Photo of this item',
  },

  add: {
    /** Header title, read by the root layout. */
    title: 'Add an item',
    titleTo: (container: string) => `Add to ${container}`,
    placeTitle: 'Where does it go?',
    back: 'Back',
    nameLabel: 'What is it?',
    /** Spoken in place of the question; the field is required. */
    nameA11y: 'Name, required',
    namePlaceholder: 'For example, AA batteries',
    nameRequired: 'Give the item a name.',
    addPhoto: 'Add a photo',
    photoOptions: 'Photo options',
    retake: 'Retake',
    removePhoto: 'Remove photo',
    where: 'Where it goes',
    dropZone: 'Drop zone',
    sortLater: 'Sort it later',
    elsewhere: 'Somewhere else…',
    elsewhereHint: 'Shows every space and container',
    /** The places read failed; the list then holds only the drop zone. */
    placesFailed: 'Your containers could not be loaded. The drop zone still works.',
    howMany: 'How many',
    snapSeveral: 'Snap several at once…',
    save: 'Save',
    saveA11yDropZone: 'Save to the drop zone',
    saveA11y: (container: string, space: string) => `Save in ${container}, ${space}`,
    saveAndAnother: 'Save and add another',
    savedIn: (container: string, space: string) => `Saved in ${container} (${space}).`,
    savedInDropZone: 'Saved in the drop zone.',
    /** Only while the chosen container's details have not loaded yet. */
    saved: 'Saved.',
    savedNext: 'Saved. Add the next one.',
    undoA11y: (name: string) => `Undo adding ${name}`,
    removedAgain: 'Removed again.',
    undoFailed: (offline: boolean) =>
      offline
        ? 'It was not removed. Check the connection and try again.'
        : 'It was not removed. Try again.',
    draft: 'These are your unsaved details from earlier.',
    clearDraft: 'Clear',
    discardTitle: 'Discard this item?',
    discardBody: 'What you typed will be lost.',
  },

  dropZone: {
    title: 'Drop zone',
    quickSnap: 'Quick Snap',
    intro2: (count: number) =>
      `${plural(count, 'item', 'items')} waiting for a place. Open one to name it, then file it.`,
    emptyAll: {
      title: 'Everything is filed',
      body: 'Items added without a place, and Quick Snap photos, wait here until they get a home.',
      action: 'Quick Snap',
    },
  },
  capture: {
    modeLabel: 'Capture mode',
    modeSingle: 'One item',
    modeFast: 'Several',
    singleHint: 'Tap to focus, then fill the frame.',
    tapToFocus: 'Focus camera',
    fastHint: 'Keep shooting. Each photo becomes an item.',
    saving: 'Saving your photo…',
    done: 'Done',
    /** The font has no ✓; the status pill draws a `check` icon instead. */
    identified: (count: number) => `${count} identified`,
    identifying: (count: number) => `Identifying ${count}…`,
    /** Some came back named, some did not — report both rather than the total. */
    identifiedPartly: (identified: number, unnamed: number) =>
      `${identified} identified · ${unnamed} to name`,
    /** Recognition gave us nothing; the photos are still safely saved. */
    savedUnnamed: (count: number) => `${count} saved · name ${count === 1 ? 'it' : 'them'} later`,
    failedSome: (count: number) =>
      `${count} photo${count === 1 ? '' : 's'} could not be saved. Nothing else was lost.`,
    into: 'Into the drop zone',
    /** The "Into" pill over the camera, spoken: where the photos will go. */
    intoContainerA11y: (container: string, space: string, spelled: string) =>
      `Photos go into ${container}, in ${space}, label ${spelled}`,
    intoSpaceA11y: (space: string, spelled: string) =>
      `Photos go into the container in ${space}, label ${spelled}`,
    intoDropZoneA11y: 'Photos go into the drop zone',
    close: 'Close camera',
    flash: (on: boolean) => `Flash, ${on ? 'on' : 'off'}`,
    finishSetFirst: 'Finish this set first',
    library: 'Choose a photo',
    manual: 'Type it instead',
    takePhoto: 'Take photo',
    doneA11y: (count: number) =>
      count === 0 ? 'Done' : `Done, ${plural(count, 'photo', 'photos')} taken`,
    didNotStart: 'The camera did not start. Close and try again, or type it instead.',
    libraryFailed: 'That photo could not be opened.',
    noPhoto: 'The camera did not take the photo. Try again, or type it instead.',
    notProcessed: 'That photo could not be saved. Try again, or type it instead.',
    noRoom:
      'There is not enough free space on this phone for a photo. Free some space, or type it instead.',
  },
  review: {
    title: 'Review',
    /** Short enough to keep "the drop zone" on one line at 390 pt. */
    savedTo: (count: number, container: string) => `${count} saved to ${container}`,
    savedToDropZone: (count: number) => `${count} saved to the drop zone`,
    /** Before the first row lands: what is happening, rather than "0 saved". */
    savingTitle: (count: number) => `Saving ${plural(count, 'photo', 'photos')}…`,
    savingFirst: 'They appear here as they are saved.',
    pending: (count: number) => `Saving ${count} more…`,
    toName: (count: number) =>
      count === 1 ? '1 still needs a name' : `${count} still need a name`,
    allNamed: 'All named',
    maybeLost: 'Some photos may not have been saved.',
    done: 'Done',
    keepShooting: 'Keep shooting',
    doneDropZone: (count: number) =>
      count === 1 ? '1 item is in the drop zone.' : `${count} items are in the drop zone.`,
    doneContainer: (count: number, container: string) =>
      `${plural(count, 'item', 'items')} added to ${container}.`,
    viewDropZoneA11y: 'View the drop zone',
    deleteTitle: 'Delete this item?',
    deleteBodyPaired:
      'This removes it and its photo from the household, on every phone. This cannot be undone.',
    deleteBodyLocal: 'This removes it and its photo from this phone. This cannot be undone.',
    deleteFailed: (offline: boolean) =>
      offline
        ? 'The item was not deleted. Check the connection and try again.'
        : 'The item was not deleted. Try again.',
    nothing: {
      title: 'Nothing was saved',
      body: 'None of the photos from this set could be saved. Go back and try again.',
      action: 'Try again',
    },
    /** Every row of the set was deleted or filed elsewhere: not a failure, so not "Nothing was saved". */
    emptied: {
      title: 'Nothing left in this set',
      body: 'Its items have been deleted or moved somewhere else. Keep shooting, or tap Done.',
    },
  },

  scan: {
    title: 'Scan a label',
    hint: 'Point the camera at the label on a box.',
    invalidTitle: 'Not one of our labels',
    invalidBody: 'That code was not made by this app.',
    scanAgain: 'Scan again',
    typeCode: 'Type a code instead',
    codeTitle: 'Type a label code',
    codePlaceholder: 'For example, BOX-7K2M',
    backToCamera: 'Back to the camera',
    /** While a scanned label is looked up (over the network when paired). */
    opening: 'Opening that label…',
  },
  deepLink: {
    /** Header title, read by the root layout. */
    title: 'QR label',
    opening: 'Opening that label…',
    newTitle: 'New label',
    newBody: 'This label is not linked to a container yet. Choose the one it is stuck on.',
    replaceTitle: (label: string) => `Replace the label on ${label}?`,
    replaceBody: (label: string) =>
      `${label} already has a label. Its old sticker will stop opening it.`,
    replace: 'Replace',
    linked: (label: string) => `Label linked to ${label}.`,
    /** Nothing was written, and the label is still waiting on this screen. */
    linkFailed: (offline: boolean) =>
      offline
        ? 'The label was not linked. Check the connection and try again.'
        : 'The label was not linked. Try again.',
    containerGone: 'That container is not in the household any more. Choose another one.',
  },

  settings: {
    /** Header title, read by the root layout. */
    title: 'Settings',
    household: 'Household',
    joinedAs: (name: string) => `Joined as “${name}”`,
    thisPhoneOnly: 'This phone only',
    onThisPhone: 'On this phone',
    backup: 'Off-device backup',
    help: 'Help',
    howItWorks: 'How it works',
    privacy: 'Privacy and your data',
    about: 'About',
    version: 'Version',
    technical: 'Technical details',
    environment: 'Environment',
    schema: 'Database schema',
    schemaValue: (version: number) => `v${version}`,
    suggestions: 'Photo suggestions',
    suggestionsOn: 'On',
    suggestionsOff: 'Not set up',
    serverAddress: 'Home server address',
    backupSummary: {
      off: 'Off',
      on: 'On',
      notYetRun: 'On, not yet run',
      working: 'Backing up…',
      attention: 'Needs attention',
      /** The words Photo suggestions uses; short, since this row's value sits beside its label. */
      notConfigured: 'Not set up',
    },
  },
  household: {
    /** Header title, read by the root layout. */
    screenTitle: 'Household',
    joinHeading: 'Join your household',
    joinBody: 'Joining lets this phone see and change the same inventory as everyone else at home.',
    thisPhoneIs: (name: string) => `This phone is “${name}”`,
    partOf: (household: string) => `Part of ${household}.`,
    phones: 'Phones in this household',
    thisPhone: 'This phone',
    lastUsed: (ago: string) => `Last used ${ago}`,
    neverUsed: 'Never used',
    /** A phone's row, spoken: its name, then "This phone" or when it was last used. */
    phoneA11y: (name: string, meta: string) => `${name}, ${meta}`,
    remove: 'Remove…',
    removeA11y: (name: string) => `Remove ${name}`,
    removeTitle: (name: string) => `Remove “${name}”?`,
    removeBody:
      'It stops seeing and changing the household straight away. Nothing in the inventory is deleted. It can join again with the household code.',
    removeConfirm: 'Remove',
    removed: (name: string) => `${name} was removed.`,
    removeOffline: (name: string) =>
      `“${name}” was not removed. Check the internet connection and try again.`,
    /** Where the list would be while the home server is out of reach; the connection banner offers "Try again". */
    phonesOffline: 'The phones show up here when the home server answers.',
    importNotice: (spaces: number, items: number) =>
      `Before it joined, this phone had its own inventory: ${sentenceList([plural(spaces, 'space', 'spaces'), plural(items, 'item', 'items')])}.`,
    importAction: 'Copy it into the household…',
    notNeeded: 'Not needed',
    importConfirmTitle: 'Copy this phone’s inventory into the household?',
    importConfirmBody:
      'Its spaces, containers, items and photos are added to the household inventory. Do this before adding or changing things on this phone, so nothing newer is overwritten.',
    importConfirm: 'Copy',
    copied: (items: number, photos: number) =>
      `Copied ${plural(items, 'item', 'items')} and ${plural(photos, 'photo', 'photos')} into the household.`,
    leave: 'Leave the household…',
    leaveTitle: 'Leave the household?',
    leaveBody:
      'This phone stops showing the household inventory. What it saw while joined stays on this phone as a copy that may be incomplete. The household and the other phones are not changed.',
    leaveConfirm: 'Leave',
    left: 'This phone has left the household.',
    joined: (household: string) => `This phone is now part of ${household}.`,
    server: (host: string) => `Home server: ${host}`,
  },
  join: {
    codeLabel: 'Household code',
    codeHint:
      'Ask whoever set up the home server. It was shown once, when the household was created. Small letters and missing hyphens are fine.',
    nameLabel: 'Name for this phone',
    namePlaceholder: 'Name this phone',
    nameHint: 'The other phones see this name. It can’t be changed later without joining again.',
    submit: 'Join household',
    busy: 'Joining…',
    badChars: (chars: string) =>
      `That code has a character it never uses (${chars}). Check it with whoever set up the home server.`,
    /** Nothing typed: it replaces the hint, so it says again where the code comes from. */
    codeRequired: 'Type the household code. Whoever set up the home server has it.',
    wrongLength: (count: number) => `The code has 26 letters and numbers. This one has ${count}.`,
    nameRequired: 'Give this phone a name.',
    refused: 'That code was not accepted. Check it with whoever set up the home server.',
    offline:
      'The home server did not answer. Check that this phone is online, then try again. Joining needs the internet, even at home.',
    other: 'Joining did not work. Try again in a moment.',
  },
  backup: {
    /** Header title, read by the root layout. */
    title: 'Backup',
    unavailable:
      'Backup is not set up in this build. Everything stays on this phone, and uninstalling the app deletes it.',
    pairedNote:
      'This phone is part of a household. The home server keeps the household’s inventory; this backup covers only the copy kept on this phone.',
    keepTitle: 'Keep a copy off this phone',
    keepBody:
      'If this phone is lost, reset or the app is uninstalled, the inventory goes with it. Backup keeps a copy of the database and photos somewhere else, so you can get them back.',
    keepCode:
      'There is no account and no email: a recovery code is the only way back to the backup, and nobody can recover it for you.',
    turnOn: 'Turn on backup',
    turnOnHint: 'Creates a recovery code and uploads a first backup',
    restoreTitle: 'Restore from a recovery code',
    restoreBody:
      'Enter it to bring a backed-up inventory onto this phone. This replaces what is on this phone now.',
    codeLabel: 'Recovery code',
    codeHint: 'Small letters and missing hyphens are fine.',
    badChars: (chars: string) =>
      `That code has a character it never uses (${chars}). Check it against where you wrote it down.`,
    restore: 'Restore…',
    restoreConfirmTitle: 'Replace what is on this phone?',
    restoreConfirmBody:
      'Everything on this phone is replaced by the backup. This cannot be undone.',
    restoreConfirm: 'Replace',
    restored: 'Your inventory is back. Photos will finish downloading shortly.',
    writeDownTitle: 'Write this down now',
    writeDownBody:
      'This is the only way back to your backup. It is not stored anywhere else, and it cannot be issued again.',
    share: 'Share recovery code…',
    saved: 'I have saved it',
    onTitle: 'Backup is on',
    lastBackup: (ago: string) => `Last backup ${ago}`,
    noBackupYet: 'No backup has finished yet.',
    working: 'Backing up…',
    automatic: 'Backups run automatically when you open the app, at most once every 15 minutes.',
    backUpNow: 'Back up now',
    errorTitle: 'The last backup did not finish',
    codeTitle: 'Your recovery code',
    codeBody:
      'Needed to restore onto a new phone. Treat it like a password: anyone who has it can read this inventory.',
    showCode: 'Show recovery code',
    /** Every way a backup or restore can fail, in plain words (was `describe()` in backup.tsx). */
    reasons: {
      malformed:
        'That code is not complete. It is 26 characters, usually written in groups of five.',
      offline:
        'No connection. Your inventory is safe on this phone. Try again when you are back online.',
      timeout: 'The connection timed out before the backup finished. Try again.',
      unauthorized: 'That code was not accepted.',
      notFound: 'There is no backup stored under that code yet.',
      quotaExceeded: 'This account has reached its storage limit.',
      tooLarge: 'This inventory is too large for a single backup.',
      corrupted: 'That backup could not be read. Nothing on this phone was changed.',
      notConfigured: 'Backup is not available in this build.',
      other: 'The backup service could not be reached. Your inventory is safe on this phone.',
    },
  },
  // Owner to approve before release: privacy notice (#8).
  privacy: {
    /** Header title, read by the root layout. */
    title: 'Privacy and your data',
    householdTitle: 'When this phone is part of a household',
    householdBody:
      'The inventory lives on your household’s home server, and this phone keeps a copy of what it reads and writes. Photos are stored in the household’s private storage, so every phone in the household can see them. Changes need an internet connection, even at home. Other phones in the household can see everything you add.',
    whereTitle: 'Where your inventory lives',
    whereBody:
      'Spaces, containers, items, notes and photos are stored in a database on this phone. That copy is the one the app reads from, and everything keeps working with no network at all.',
    whereBodyPaired:
      'Spaces, containers, items, notes and photos this phone has read or written are kept in a database on this phone.',
    backupOff:
      'Backup is off unless you turn it on. If you do, a copy of that database and your photos is uploaded so you can get them back after losing or replacing this phone. If you leave it off, nothing is uploaded and uninstalling the app deletes everything.',
    backupOffPaired:
      'Backup is off unless you turn it on. If you do, a copy of this phone’s database and photos is uploaded so you can get them back after losing or replacing this phone. If you leave it off, uninstalling the app deletes this phone’s copy; the household’s inventory stays on the home server.',
    noBackupService:
      'Backup is not set up in this build, so nothing is uploaded anywhere. Uninstalling the app deletes all of it.',
    noBackupServicePaired:
      'Backup is not set up in this build, so this phone’s copy is not uploaded anywhere else. Uninstalling the app deletes that copy.',
    backupTitle: 'If you turn on backup',
    backupAccount:
      'There is no account, no email address and no password. The app generates a recovery code on this phone and stores your backup under a name derived from it. That code is the only way to reach the backup, including for us. It is not recoverable, and if you lose it the backup cannot be opened by anyone, including you.',
    backupPassword:
      'Anyone who has the code can read that inventory, so it is worth treating like a password. Uploads travel over an encrypted connection. Your five most recent database snapshots are kept, so a mistake you notice later can still be undone.',
    backupLocal:
      'Turning backup on does not change what is on this phone. Deleting an item deletes the stored copy of its photo too.',
    cameraTitle: 'Camera and photos',
    cameraUse:
      'The camera is used for two things: photographing an item you are adding, and scanning a QR label.',
    photosLocal:
      'Photos you take in the app are saved to the app’s own private storage, not to your camera roll.',
    photosPaired:
      'Photos you take in the app are saved to the app’s own private storage and, while this phone is part of a household, to the household’s private storage. They are not saved to your camera roll.',
    photosResized: (maxDimension: number) =>
      `Importing a photo copies it; the original is left untouched. Each photo is resized to at most ${maxDimension} pixels on its long edge and re-encoded as a WebP image before it is saved, alongside a small thumbnail used in lists.`,
    photosDeleted:
      'Deleting an item, its container or its space also deletes the photo file from this phone.',
    suggestionsTitle: 'Photo suggestions',
    suggestionsSent:
      'When you add an item with a photo, that single image is sent to our service to suggest a name, category and tags. The suggestion is only a suggestion: you can edit or ignore it, and saving an item never requires it.',
    suggestionsPrivate:
      'Images are sent for that one request and are not used to build a profile of you. Your notes and other item details are never sent.',
    suggestionsOff:
      'Photo suggestions are not configured in this build, so no image is ever sent for suggestions. Items are always added by typing the details.',
    diagnosticsTitle: 'Diagnostics',
    diagnosticsBody:
      'Diagnostic events record only timings and outcome categories: how long something took and whether it succeeded. Item names, notes, photos, search text and QR codes are filtered out before anything is recorded, and no crash or analytics provider is enabled in this build.',
    offlineTitle: 'Working offline',
    offlineBody:
      'Everything except photo suggestions and backup works with no network connection at all, including adding items, scanning labels and searching. Backups wait for a connection and catch up on their own; nothing you do is blocked while they wait.',
    offlinePaired:
      'Searching and browsing what this phone last loaded can work without the internet. Adding and changing things needs it.',
  },
  onboarding: {
    start: 'Start',
    brand: 'Inventory',
    title: 'Find where anything is kept',
    facts: [
      'Type what you remember. The answer is the place it is kept.',
      'Add items in seconds. Choosing a place can wait.',
      'Scan the label on a box to see what is inside.',
    ],
    join: 'Join your household',
    local: 'Use this phone on its own',
    continue: 'Continue',
    back: 'Back',
    joinedTitle: 'You are in',
    joinedBody: (household: string) => `Everything stored in ${household} is on this phone now.`,
  },
} as const;
