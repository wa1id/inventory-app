import GRDB
import InventoryCore

#if DEBUG
// DEBUG only (the demo and the tests): kept out of Release builds, which must hold none of the
// demo's names (scripts/release/check-release.sh).

/// A large, deterministic inventory for performance work (00-index M9, docs/PERFORMANCE.md):
/// 10 000 items in 20 spaces and 250 containers, 300 of them waiting in the drop zone and 500
/// in one big container, with accented names, categories, tags, notes and quantities from 0
/// up. The DEBUG demo writes it with `-demo YES -demoSeed large`, and the performance tests
/// measure against it.
///
/// Everything is drawn from a seeded generator, so two runs with the same ``Shape`` write the
/// same rows, ids included. The rows are written straight with the repositories' own folds
/// (`itemSearchText`, `normalizedTagName`), byte for byte what `items.create` would store, in
/// whatever transaction the caller holds: one transaction for the whole inventory takes a
/// fraction of a second, where one `create` per item would take several.
///
/// Debug and test use only: compiled into DEBUG builds alone, never written on a device.
public enum PerfInventorySeed {
    /// How much to write. ``large`` is the M9 inventory; tests scale it down.
    public struct Shape: Sendable, Hashable {
        /// Every item, drop zone included.
        public var items: Int
        /// User spaces (the drop zone's own space is not counted).
        public var spaces: Int
        /// User containers (the drop zone's own container is not counted).
        public var containers: Int
        /// Items waiting in the drop zone, besides the small demo inventory's three.
        public var dropZoneItems: Int
        /// Items in ``PerfInventorySeed/bigContainerName``.
        public var bigContainerItems: Int
        /// Containers with a QR label.
        public var labelledContainers: Int
        /// The generator's seed.
        public var seed: UInt64

        public init(
            items: Int, spaces: Int, containers: Int, dropZoneItems: Int,
            bigContainerItems: Int, labelledContainers: Int, seed: UInt64 = 0x5EED_1A26_E000_0001
        ) {
            self.items = items
            self.spaces = spaces
            self.containers = containers
            self.dropZoneItems = dropZoneItems
            self.bigContainerItems = bigContainerItems
            self.labelledContainers = labelledContainers
            self.seed = seed
        }

        /// 10 000 items, 20 spaces, 250 containers, 300 in the drop zone, 500 in the big
        /// container, 40 labels.
        public static let large = Shape(
            items: 10_000, spaces: 20, containers: 250, dropZoneItems: 300,
            bigContainerItems: 500, labelledContainers: 40)

        /// ``large`` with `items` items and the other counts in proportion (at least the six
        /// named containers and three named spaces).
        public static func scaled(items: Int) -> Shape {
            let ratio = Double(max(1, items)) / Double(large.items)
            func scale(_ value: Int, minimum: Int) -> Int { max(minimum, Int((Double(value) * ratio).rounded())) }
            return Shape(
                items: max(1, items),
                spaces: scale(large.spaces, minimum: 4),
                containers: scale(large.containers, minimum: 8),
                dropZoneItems: scale(large.dropZoneItems, minimum: 1),
                bigContainerItems: scale(large.bigContainerItems, minimum: 1),
                labelledContainers: scale(large.labelledContainers, minimum: 1))
        }
    }

    /// What was written, for tests and the demo.
    public struct Summary: Sendable, Hashable {
        /// User spaces, in the order written.
        public var spaceIds: [String]
        /// User containers, in the order written (the big container first).
        public var containerIds: [String]
        /// ``PerfInventorySeed/bigContainerName``.
        public var bigContainerId: String
        /// ``PerfInventorySeed/bigSpaceName``.
        public var bigSpaceId: String
        /// Every item written.
        public var itemCount: Int
        /// Items in the drop zone.
        public var dropZoneItemCount: Int
        /// Items with a photo row.
        public var photoCount: Int
        /// Distinct tags.
        public var tagCount: Int
        /// Six containers, most recent first, to store as the recent places.
        public var recentPlaceIds: [String]
    }

    /// The big container's name and code (`-demoRoute container:Parts_bin`).
    public static let bigContainerName = "Parts bin"
    public static let bigContainerCode = "BIN-P4RT"
    /// The space that holds the big container.
    public static let bigSpaceName = "Workshop"

    /// Writes the inventory into an empty, migrated database, inside the caller's transaction.
    ///
    /// - Parameters:
    ///   - shape: how much to write.
    ///   - photos: one photo per entry, each given to a different item spread through the
    ///     inventory (drop zone included). Pass distinct files: a row's files are deleted with
    ///     it. ``placeholderPhotos(count:)`` gives rows whose files do not exist.
    ///   - now: the newest `created_at`; the items reach back about two years from it.
    public static func write(
        _ shape: Shape = .large,
        photos: [ItemPhotoInput] = [],
        now: Int64,
        in db: Database
    ) throws -> Summary {
        var writer = Writer(shape: shape, now: now, db: db)
        return try writer.write(photos: photos)
    }

    /// Photo rows whose files do not exist: the SQL costs of real photos without the bytes.
    public static func placeholderPhotos(count: Int) -> [ItemPhotoInput] {
        (0..<max(0, count)).map { index in
            ItemPhotoInput(
                uri: "file:///perf/item-photos/perf-\(index).webp",
                thumbUri: "file:///perf/item-photos/perf-\(index)-thumb.webp",
                width: 1400, height: 1050, byteSize: 180_000)
        }
    }

    // MARK: The generator

    /// SplitMix64: small, fast and the same on every platform.
    struct Generator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// 0..<bound (bound > 0).
        mutating func below(_ bound: Int) -> Int {
            Int(next() % UInt64(max(1, bound)))
        }

        /// True with probability `percent` / 100.
        mutating func chance(_ percent: Int) -> Bool {
            below(100) < percent
        }

        mutating func pick<T>(_ values: [T]) -> T {
            values[below(values.count)]
        }

        mutating func bytes(_ count: Int) -> [UInt8] {
            var out: [UInt8] = []
            out.reserveCapacity(count)
            while out.count < count {
                var word = next()
                for _ in 0..<min(8, count - out.count) {
                    out.append(UInt8(truncatingIfNeeded: word))
                    word >>= 8
                }
            }
            return out
        }
    }

    /// Hands `newId` and `newQrToken` the generator's bytes, so ids are deterministic too.
    struct FixedBytes: RandomByteSource {
        let bytes: [UInt8]

        func randomBytes(count: Int) -> [UInt8] {
            Array(bytes.prefix(count)) + [UInt8](repeating: 0, count: max(0, count - bytes.count))
        }
    }

    private struct Writer {
        let shape: Shape
        let now: Int64
        let db: Database
        var random: Generator
        var usedCodes: Set<String> = ["DROP-ZONE"]
        var tagIds: [String: String] = [:]

        init(shape: Shape, now: Int64, db: Database) {
            self.shape = shape
            self.now = now
            self.db = db
            random = Generator(seed: shape.seed)
        }

        mutating func id() -> String {
            newId(using: FixedBytes(bytes: random.bytes(16)))
        }

        mutating func write(photos: [ItemPhotoInput]) throws -> Summary {
            let start = now - 2 * 365 * 24 * 3_600_000
            let (spaceIds, bigSpaceId) = try writeSpaces(at: start)
            let (containerIds, bigContainerId) = try writeContainers(spaceIds: spaceIds, bigSpaceId: bigSpaceId, at: start)
            try writeLabels(containerIds: containerIds, at: start)

            let plan = itemPlan(containerIds: containerIds, bigContainerId: bigContainerId)
            let photoSlots = Self.photoSlots(items: plan.count, photos: photos.count)
            let step = max(1, (now - start) / Int64(max(1, plan.count)))

            let insertItem = try db.cachedStatement(sql: """
                INSERT INTO items (id, container_id, name, category, quantity, notes, created_at, updated_at, search_text)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            let insertLink = try db.cachedStatement(sql: "INSERT INTO item_tags (item_id, tag_id) VALUES (?, ?)")
            let insertPhoto = try db.cachedStatement(sql: """
                INSERT INTO item_photos (id, item_id, uri, thumb_uri, width, height, byte_size, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """)

            var dropZoneCount = 0
            var photoCount = 0
            for (index, containerId) in plan.enumerated() {
                let createdAt = start + Int64(index) * step + Int64(random.below(Int(max(1, step / 2))))
                let inDropZone = containerId == DropZone.containerId
                if inDropZone { dropZoneCount += 1 }
                let fixture = index >= plan.count - PerfInventorySeed.newestFixtures.count && !plan.isEmpty
                    ? PerfInventorySeed.newestFixtures[index - (plan.count - PerfInventorySeed.newestFixtures.count)]
                    : nil
                let draft = fixture.map { ItemDraftValues(name: $0.name, category: $0.category, quantity: $0.quantity, notes: $0.notes, tags: $0.tags) }
                    ?? makeItem(inDropZone: inDropZone)
                let itemId = id()
                try insertItem.execute(arguments: [
                    itemId, containerId, draft.name, draft.category, draft.quantity, draft.notes,
                    createdAt, createdAt, itemSearchText(name: draft.name, category: draft.category),
                ])
                var linked = Set<String>()
                for tag in draft.tags {
                    let tagId = try tagId(for: tag, at: createdAt)
                    guard linked.insert(tagId).inserted else { continue }
                    try insertLink.execute(arguments: [itemId, tagId])
                }
                if let slot = photoSlots[index] {
                    let photo = photos[slot]
                    try insertPhoto.execute(arguments: [
                        photo.id ?? id(), itemId, photo.uri, photo.thumbUri, photo.width, photo.height, photo.byteSize, createdAt,
                    ])
                    photoCount += 1
                }
            }

            // The places she filed into last: the big container and five more, newest first.
            let recent = [bigContainerId] + containerIds.filter { $0 != bigContainerId }.prefix(5)
            return Summary(
                spaceIds: spaceIds,
                containerIds: containerIds,
                bigContainerId: bigContainerId,
                bigSpaceId: bigSpaceId,
                itemCount: plan.count,
                dropZoneItemCount: dropZoneCount,
                photoCount: photoCount,
                tagCount: tagIds.count,
                recentPlaceIds: Array(recent))
        }

        // MARK: Spaces and containers

        mutating func writeSpaces(at time: Int64) throws -> ([String], String) {
            let insert = try db.cachedStatement(sql: "INSERT INTO spaces (id, name, icon, color, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)")
            var ids: [String] = []
            var bigSpaceId = ""
            for index in 0..<max(1, shape.spaces) {
                let preset = PerfInventorySeed.spaces[index % PerfInventorySeed.spaces.count]
                let name = index < PerfInventorySeed.spaces.count ? preset.name : "\(preset.name) \(index / PerfInventorySeed.spaces.count + 1)"
                let spaceId = id()
                let at = time + Int64(index) * 60_000
                try insert.execute(arguments: [spaceId, name, preset.icon, PerfInventorySeed.colors[index % PerfInventorySeed.colors.count], at, at])
                ids.append(spaceId)
                if name == PerfInventorySeed.bigSpaceName { bigSpaceId = spaceId }
            }
            if bigSpaceId.isEmpty { bigSpaceId = ids[ids.count - 1] }
            return (ids, bigSpaceId)
        }

        mutating func writeContainers(spaceIds: [String], bigSpaceId: String, at time: Int64) throws -> ([String], String) {
            let insert = try db.cachedStatement(sql: """
                INSERT INTO containers (id, space_id, name, visual_type, short_code, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """)
            var ids: [String] = []
            let bigId = id()
            usedCodes.insert(PerfInventorySeed.bigContainerCode)
            try insert.execute(arguments: [bigId, bigSpaceId, PerfInventorySeed.bigContainerName, ContainerVisualType.bin.rawValue, PerfInventorySeed.bigContainerCode, time, time])
            ids.append(bigId)

            // The six containers of the small demo inventory, with its codes, in its first three spaces.
            for (offset, named) in PerfInventorySeed.namedContainers.enumerated() where ids.count < max(1, shape.containers) {
                let containerId = id()
                usedCodes.insert(named.code)
                let at = time + Int64(offset + 1) * 60_000
                try insert.execute(arguments: [containerId, spaceIds[named.space % spaceIds.count], named.name, named.type.rawValue, named.code, at, at])
                ids.append(containerId)
            }

            while ids.count < max(1, shape.containers) {
                let index = ids.count
                let type = PerfInventorySeed.containerTypes[index % PerfInventorySeed.containerTypes.count]
                let name: String? = random.chance(8) ? nil : containerName(type: type, index: index)
                let code = uniqueCode(type)
                let spaceId = spaceIds[random.below(spaceIds.count)]
                let containerId = id()
                let at = time + Int64(index) * 3_600_000
                try insert.execute(arguments: [containerId, spaceId, name, type.rawValue, code, at, at])
                ids.append(containerId)
            }
            return (ids, bigId)
        }

        mutating func writeLabels(containerIds: [String], at time: Int64) throws {
            let insert = try db.cachedStatement(sql: "INSERT INTO qr_bindings (id, token, container_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?)")
            for containerId in containerIds.prefix(max(0, shape.labelledContainers)) {
                try insert.execute(arguments: [id(), newQrToken(using: FixedBytes(bytes: random.bytes(16))), containerId, time, time])
            }
        }

        mutating func containerName(type: ContainerVisualType, index: Int) -> String {
            let noun = PerfInventorySeed.containerNouns[type] ?? "Box"
            switch random.below(4) {
            case 0: return "\(random.pick(PerfInventorySeed.colorWords)) \(noun.lowercased())"
            case 1: return "\(noun) \(index)"
            case 2: return "\(noun) \(random.pick(["A", "B", "C", "D"]))\(random.below(9) + 1)"
            default: return "\(random.pick(PerfInventorySeed.containerTopics)) \(noun.lowercased())"
            }
        }

        mutating func uniqueCode(_ type: ContainerVisualType) -> String {
            while true {
                var generator = SeededNumbers(random: random)
                let code = generateShortCode(type, using: &generator)
                random = generator.random
                if usedCodes.insert(code).inserted { return code }
            }
        }

        // MARK: Items

        /// Where each item goes, oldest first: the big container's items and the rest spread over
        /// the user containers, with the drop zone's items among the newest (Quick Snap shots
        /// waiting to be filed).
        mutating func itemPlan(containerIds: [String], bigContainerId: String) -> [String] {
            let total = max(0, shape.items)
            // The newest few are the small demo inventory's named items, in their own places.
            let fixtures = PerfInventorySeed.newestFixtures.suffix(min(PerfInventorySeed.newestFixtures.count, total))
            let dropZone = min(max(0, shape.dropZoneItems), total - fixtures.count)
            let big = min(max(0, shape.bigContainerItems), total - fixtures.count - dropZone)
            let spread = total - fixtures.count - dropZone - big
            var filed = [String](repeating: bigContainerId, count: big)
            let others = containerIds.filter { $0 != bigContainerId }
            // Uneven: some containers hold a handful, some sixty.
            let weights = others.map { _ in 1 + random.below(6) }
            let weightSum = max(1, weights.reduce(0, +))
            var remaining = spread
            for (index, containerId) in others.enumerated() where remaining > 0 {
                let count = index == others.count - 1 ? remaining : min(remaining, spread * weights[index] / weightSum)
                filed += [String](repeating: containerId, count: count)
                remaining -= count
            }
            if remaining > 0 { filed += [String](repeating: others.first ?? bigContainerId, count: remaining) }
            // Shuffle (Fisher–Yates on the seeded generator).
            if filed.count > 1 {
                for index in stride(from: filed.count - 1, to: 0, by: -1) {
                    filed.swapAt(index, random.below(index + 1))
                }
            }
            // The drop zone's items land among the newest 1 500.
            var plan = filed
            let window = min(plan.count, 1_500)
            for _ in 0..<dropZone {
                let position = plan.count - random.below(window + 1)
                plan.insert(DropZone.containerId, at: max(0, min(plan.count, position)))
            }
            for fixture in fixtures {
                if fixture.dropZone {
                    plan.append(DropZone.containerId)
                } else if let container = PerfInventorySeed.namedContainers.firstIndex(where: { $0.name == fixture.container }),
                          container + 1 < containerIds.count {
                    plan.append(containerIds[container + 1])
                } else {
                    plan.append(others.first ?? bigContainerId)
                }
            }
            return plan
        }

        struct ItemDraftValues {
            var name: String
            var category: String?
            var quantity: Int
            var notes: String?
            var tags: [String]
        }

        mutating func makeItem(inDropZone: Bool) -> ItemDraftValues {
            // Quick Snap shots nobody named yet.
            if inDropZone && random.chance(8) {
                return ItemDraftValues(name: "", category: nil, quantity: 1, notes: nil, tags: [])
            }
            var name = random.chance(28) ? random.pick(PerfInventorySeed.accentedNouns) : random.pick(PerfInventorySeed.nouns)
            if random.chance(45) { name = "\(random.pick(PerfInventorySeed.descriptors)) \(name)" }
            if random.chance(35) { name += " \(random.pick(PerfInventorySeed.suffixes))" }
            name = name.prefix(1).uppercased() + name.dropFirst()

            let category: String? = random.chance(22) ? nil : random.pick(PerfInventorySeed.categories)
            let quantity: Int = switch random.below(100) {
            case 0..<6: 0
            case 6..<72: 1
            case 72..<94: 2 + random.below(11)
            default: 20 + random.below(481)
            }
            let notes: String? = random.chance(30) ? random.pick(PerfInventorySeed.notes) : nil
            var tags: [String] = []
            if random.chance(58) {
                for _ in 0..<(1 + random.below(3)) { tags.append(random.pick(PerfInventorySeed.tags)) }
            }
            return ItemDraftValues(name: name, category: category, quantity: quantity, notes: notes, tags: tags)
        }

        mutating func tagId(for name: String, at time: Int64) throws -> String {
            let normalized = normalizedTagName(name)
            if let existing = tagIds[normalized] { return existing }
            let tagId = id()
            try db.cachedStatement(sql: "INSERT INTO tags (id, name, normalized_name, created_at) VALUES (?, ?, ?, ?)")
                .execute(arguments: [tagId, name, normalized, time])
            tagIds[normalized] = tagId
            return tagId
        }

        /// The item index each photo goes to: spread evenly, the newest item included.
        static func photoSlots(items: Int, photos: Int) -> [Int: Int] {
            guard items > 0, photos > 0 else { return [:] }
            let count = min(items, photos)
            var slots: [Int: Int] = [:]
            for photo in 0..<count {
                slots[items - 1 - photo * items / count] = photo
            }
            return slots
        }
    }

    /// `RandomNumberGenerator` over ``Generator`` for `generateShortCode(_:using:)`.
    private struct SeededNumbers: RandomNumberGenerator {
        var random: Generator

        mutating func next() -> UInt64 {
            random.next()
        }
    }

    // MARK: Word lists

    private static let spaces: [(name: String, icon: String)] = [
        ("Garage", "🧰"), ("Kitchen", "🍳"), ("Attic", "📦"), ("Workshop", "🧰"), ("Living room", "🛋\u{FE0F}"),
        ("Bedroom", "🛏\u{FE0F}"), ("Kids’ room", "🎒"), ("Bathroom", "🧺"), ("Office", "📚"), ("Shed", "🪴"),
        ("Hallway", "🏠"), ("Laundry room", "🧺"), ("Cellar", "📦"), ("Café corner", "🍳"), ("Dachboden", "📦"),
        ("Guest room", "🛏\u{FE0F}"), ("Balcony", "🪴"), ("Car", "🚗"), ("Studio", "📚"), ("Pantry", "🍳"),
    ]

    private static let colors = ["#5B8DEF", "#E07A5F", "#81B29A", "#2E9E4F", "#E4572E", "#B15BEF", "#E0A800", "#0F9BB0"]

    private static let namedContainers: [(name: String, type: ContainerVisualType, code: String, space: Int)] = [
        ("Tool chest", .cabinet, "CAB-J92R", 0), ("Red bin", .bin, "BIN-4F2A", 0), ("Christmas box", .box, "BOX-7K2M", 0),
        ("Pantry shelf", .shelf, "SHF-3PQX", 1), ("Top drawer", .drawer, "DRW-8HNC", 1), ("Winter clothes", .bag, "BAG-5WTD", 2),
    ]

    private static let containerTypes: [ContainerVisualType] = [.box, .bin, .drawer, .shelf, .cabinet, .bag, .crate, .other]

    private static let containerNouns: [ContainerVisualType: String] = [
        .box: "Box", .bin: "Bin", .drawer: "Drawer", .shelf: "Shelf", .cabinet: "Cabinet", .bag: "Bag", .crate: "Crate", .other: "Basket",
    ]

    private static let colorWords = ["Red", "Blue", "Green", "Black", "White", "Grey", "Yellow", "Clear", "Orange", "Pink"]

    private static let containerTopics = [
        "Cable", "Craft", "Toy", "Paperwork", "Spare parts", "Holiday", "Camping", "Garden", "Medicine", "Sewing",
        "Bits and bobs", "Électronique", "Crème", "Schuhe", "Linen", "Photo", "Kitchen", "Bike", "Car", "Winter",
    ]

    private static let nouns = [
        "screws", "nails", "hammer", "drill bits", "tape measure", "duct tape", "zip ties", "light bulbs", "AA batteries",
        "AAA batteries", "extension cord", "HDMI cable", "USB-C charger", "phone charger", "headphones", "router",
        "power bank", "keyboard", "mouse", "printer ink", "paper clips", "notebook", "pens", "stapler", "scissors",
        "glue gun", "paint brushes", "paint roller", "sandpaper", "wrench", "pliers", "screwdriver set", "socket set",
        "spirit level", "step ladder", "flashlight", "candles", "matches", "first aid kit", "plasters", "thermometer",
        "vitamins", "sunscreen", "towels", "bed sheets", "pillowcases", "blanket", "duvet", "scarf", "gloves", "beanie",
        "rain jacket", "boots", "sneakers", "sandals", "swimsuit", "backpack", "suitcase", "tent", "sleeping bag",
        "camping stove", "water bottle", "thermos", "lunch box", "mugs", "wine glasses", "plates", "bowls", "cutlery",
        "frying pan", "saucepan", "wok", "baking tray", "whisk", "rolling pin", "measuring cups", "blender", "toaster",
        "kettle", "coffee beans", "tea bags", "olive oil", "rice", "pasta", "flour", "spices", "jam jars",
        "Christmas lights", "ornaments", "wrapping paper", "gift bags", "ribbons", "board games", "jigsaw puzzle",
        "Lego", "toy cars", "crayons", "chalk", "football", "tennis rackets", "yoga mat", "dumbbells", "bike pump",
        "bike lights", "helmet", "jumper cables", "ice scraper", "snow chains", "garden hose", "seeds", "plant pots",
        "trowel", "pruning shears", "watering can", "bird feeder", "dog leash", "cat toys", "passport",
        "tax documents", "warranty cards", "user manuals", "photo albums", "old letters", "vinyl records", "DVDs",
        "guitar strings", "ukulele", "sheet music", "sewing kit", "buttons", "yarn", "knitting needles", "fabric",
        "iron", "ironing board", "vacuum bags", "mop", "sponges", "dish soap", "bin bags", "laundry detergent",
        "clothes pegs", "hangers", "shoe polish", "umbrella", "sunglasses", "watch strap", "jewellery box",
        "hair dryer", "toothbrushes", "razor blades", "shampoo", "soap bars", "tissues", "wood screws", "wall plugs",
        "picture hooks", "fuse wire", "cable ties", "hex keys", "spare keys", "padlock", "bungee cords", "tarp",
    ]

    private static let accentedNouns = [
        "café filters", "crème brûlée torch", "piñata", "jalapeño jar", "crêpe pan", "fondue set", "pâté tins",
        "gruyère grater", "smörgåsbord plates", "naïve art print", "résumé folder", "Zürich souvenirs", "Bügeleisen",
        "Kühlbox", "Schlüssel", "décor cushions", "porte-clés", "São Tomé coffee", "Ærø postcards", "Ångström ruler",
        "Łódź map", "café au lait bowls", "entrée plates", "Noël ornaments", "über charger", "jalapeño seeds",
        "señorita fan", "açaí bowls", "doña's recipes", "fiancé’s letters", "Champs-Élysées poster", "Göteborg mug",
    ]

    private static let descriptors = [
        "red", "blue", "green", "black", "white", "small", "large", "spare", "old", "new", "broken", "vintage",
        "wooden", "metal", "plastic", "glass", "kids’", "winter", "summer", "camping", "travel", "kitchen", "garden",
        "bathroom", "office", "party", "birthday", "wedding", "grandma’s", "Zoë’s", "Chloé’s", "André’s", "Renée’s",
        "José’s", "Björn’s", "Søren’s", "Inès’s", "François’s", "cheap", "good",
    ]

    private static let suffixes = [
        "M6", "M8", "4x40", "5x60", "#12", "(set of 4)", "2023", "2024", "XL", "12V", "pack", "spare", "No. 4242",
        "size 38", "1.5 m", "3 m", "USB-A", "v2", "mini", "pro",
    ]

    private static let categories = [
        "Tools", "Kitchen", "Electronics", "Batteries", "Clothes", "Food", "Garden", "Toys", "Documents", "Bathroom",
        "Cleaning", "Sports", "Medicine", "Stationery", "Holiday", "Car", "Bike", "Camping", "Office", "Pets", "Music",
        "Books", "Décor", "Crafts", "Linen", "Électronique",
    ]

    private static let tags = [
        "power tools", "fragile", "seasonal", "kids", "spare", "borrowed", "to fix", "warranty", "vintage", "café",
        "outdoor", "élégant", "gift", "sell", "donate", "keep", "travel", "camping", "winter", "summer", "party",
        "emergency", "batteries", "charger", "cables", "paint", "screws", "office", "school", "medicine", "baby",
        "dog", "cat", "bike", "car", "garden", "kitchen", "bathroom", "decor", "Noël", "birthday", "wedding",
        "souvenir", "heirloom", "lent out", "new", "old", "broken", "spares", "set", "Zoë", "André", "work", "home",
        "sport", "music", "books", "crafts", "sewing", "tools",
    ]

    private static let notes = [
        "Charger is in the red bin.", "Bought in 2023, receipt in the drawer.", "Lent to Zoë in March.",
        "Needs new batteries.", "One is missing.", "From grandma’s house.", "Check before winter.",
        "The blue one is the good one.", "Warranty until 2026.", "Spare set for the car.",
        "Don’t throw away: the box is needed for returns.", "Instructions are in the manual folder.",
        "Swap with André after the holidays.", "Café de Flore souvenir.", "Fits the old drill only.",
        "Ask Chloé before using.", "Bought at the market in Göteborg.", "Two sizes inside.",
    ]

    /// The newest items: the small demo inventory's named items, so `-demoRoute item:Cordless_drill`
    /// and the like still work with the large inventory.
    private static let newestFixtures: [(name: String, category: String?, quantity: Int, notes: String?, tags: [String], container: String, dropZone: Bool)] = [
        ("Wool scarf", "Clothes", 1, nil, [], "Winter clothes", false),
        ("AA batteries", "Batteries", 12, nil, [], "Top drawer", false),
        ("Printer ink", nil, 0, nil, [], "Top drawer", false),
        ("Olive oil", "Food", 2, nil, [], "Pantry shelf", false),
        ("Christmas lights", "Decorations", 3, nil, [], "Christmas box", false),
        ("Extension cord", nil, 2, nil, [], "Red bin", false),
        ("Screwdriver set", "Tools", 1, nil, [], "Tool chest", false),
        ("Cordless drill", "Tools", 1, "Charger is in the red bin.", ["power tools"], "Tool chest", false),
        ("HDMI cable", nil, 2, nil, [], "", true),
        ("Spare keys", nil, 1, nil, [], "", true),
        ("Bike pump", nil, 1, nil, [], "", true),
    ]
}
#endif
