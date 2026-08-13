import Foundation

/// One file, as the folder comparison sees it.
public struct TreeFile: Sendable, Hashable {
    public let path: String
    public let digest: Digest32

    public init(path: String, digest: Digest32) {
        self.path = path
        self.digest = digest
    }
}

/// The directory structure under a scan root, laid out so subtree questions are integer arithmetic.
///
/// **Two properties earn the whole type**, and both replace something the CLI does the slow way:
///
/// 1. **Euler intervals**: `a` is an ancestor of `b` exactly when `in[a] <= in[b] < out[a]`. One integer
///    comparison instead of `Path.relative_to` inside a `try/except`, which is what
///    `folder_duplicates.py:154-163` does for every one of the `D²` pairs.
/// 2. **Depth-first file order**: the files of any directory's subtree are a **contiguous range** of
///    indices. That is what lets a survivor's exact comparison read two slices instead of building two
///    dictionaries -- and it is why the files are ordered here rather than wherever the walker left them.
///
/// Children are ordered by ``PathOrder`` so the layout is reproducible: the same tree always produces the
/// same indices, which is what makes a differential test against a brute-force reference meaningful.
public struct DirectoryTree: Sendable {

    public struct Node: Sendable {
        public let path: String
        /// `nil` for the root.
        public let parent: Int?
        /// Depth below the root, which is 0.
        public let depth: Int
        /// Euler entry and exit, for the ancestor test.
        public let eulerIn: Int
        public let eulerOut: Int
        /// Files directly in this directory, as a range of ``DirectoryTree/files``.
        public let ownFiles: Range<Int>
        /// Every file at or below this directory, as one contiguous range.
        public let subtreeFiles: Range<Int>
        public let children: [Int]
    }

    /// Directories, root first, in depth-first order.
    public let nodes: [Node]
    /// Files in depth-first order, so every subtree is a contiguous slice.
    public let files: [TreeFile]
    /// Node index by path, for looking a directory up by name.
    public let indexByPath: [String: Int]

    private init(nodes: [Node], files: [TreeFile], indexByPath: [String: Int]) {
        self.nodes = nodes
        self.files = files
        self.indexByPath = indexByPath
    }

    /// Builds the tree from a flat list of files.
    ///
    /// Every directory between `root` and a file becomes a node, whether or not it holds files of its own:
    /// an intermediate directory is still a folder somebody can compare.
    ///
    /// - Parameter root: paths not under it are ignored rather than guessed at.
    public static func build(root: String, files: [TreeFile]) -> DirectoryTree {
        let rootPath = RealPath.trimmingTrailingSlashes(root)

        // Group files by their directory, splitting on `/` over raw bytes -- never normalising, like
        // everywhere else here.
        var filesByDirectory: [String: [TreeFile]] = [:]
        var directories: Set<String> = [rootPath]
        for file in files {
            let directory = (file.path as NSString).deletingLastPathComponent
            guard directory == rootPath || directory.hasPrefix(rootPath + "/") else { continue }
            filesByDirectory[directory, default: []].append(file)
            // Every ancestor up to the root is a directory in its own right.
            var current = directory
            while current != rootPath, current.count > rootPath.count {
                directories.insert(current)
                current = (current as NSString).deletingLastPathComponent
            }
        }

        var childrenOf: [String: [String]] = [:]
        for directory in directories where directory != rootPath {
            let parent = (directory as NSString).deletingLastPathComponent
            childrenOf[parent, default: []].append(directory)
        }
        for key in childrenOf.keys {
            childrenOf[key] = PathOrder.sorted(childrenOf[key] ?? [])
        }

        var nodes: [Node] = []
        var laidOutFiles: [TreeFile] = []
        var indexByPath: [String: Int] = [:]
        var euler = 0

        /// Lays out one directory and everything under it, returning its node index.
        func visit(_ path: String, parent: Int?, depth: Int) -> Int {
            let index = nodes.count
            let inValue = euler
            euler += 1
            // A placeholder, replaced once the subtree is known: the ranges cannot be computed before the
            // children have been laid out.
            nodes.append(
                Node(
                    path: path, parent: parent, depth: depth, eulerIn: inValue, eulerOut: inValue,
                    ownFiles: 0..<0, subtreeFiles: 0..<0, children: []
                )
            )
            indexByPath[path] = index

            let subtreeStart = laidOutFiles.count
            let ownStart = laidOutFiles.count
            // Own files first, sorted, so the order is reproducible.
            let own = (filesByDirectory[path] ?? []).sorted { PathOrder.lessThan($0.path, $1.path) }
            laidOutFiles.append(contentsOf: own)
            let ownRange = ownStart..<laidOutFiles.count

            var children: [Int] = []
            for child in childrenOf[path] ?? [] {
                children.append(visit(child, parent: index, depth: depth + 1))
            }
            let subtreeRange = subtreeStart..<laidOutFiles.count

            nodes[index] = Node(
                path: path, parent: parent, depth: depth, eulerIn: inValue, eulerOut: euler,
                ownFiles: ownRange, subtreeFiles: subtreeRange, children: children
            )
            return index
        }

        _ = visit(rootPath, parent: nil, depth: 0)
        return DirectoryTree(nodes: nodes, files: laidOutFiles, indexByPath: indexByPath)
    }

    /// Whether `ancestor` is at or above `descendant`.
    ///
    /// One integer comparison. The CLI asks `Path.relative_to` inside a `try/except` for every pair.
    public func isAncestor(_ ancestor: Int, of descendant: Int) -> Bool {
        guard nodes.indices.contains(ancestor), nodes.indices.contains(descendant) else {
            return false
        }
        let a = nodes[ancestor]
        let b = nodes[descendant]
        return a.eulerIn <= b.eulerIn && b.eulerIn < a.eulerOut
    }

    /// Whether either directory contains the other. The CLI skips such pairs outright.
    public func areNested(_ first: Int, _ second: Int) -> Bool {
        isAncestor(first, of: second) || isAncestor(second, of: first)
    }

    /// How many files are at or below a directory.
    ///
    /// This is exactly the CLI's `total_a`: `len(fingerprint)`, which counts every file in the subtree.
    public func subtreeFileCount(_ index: Int) -> Int {
        nodes.indices.contains(index) ? nodes[index].subtreeFiles.count : 0
    }

    /// The candidates the CLI compares: **every directory except the root**.
    ///
    /// `_collect_subdirs` gathers names out of `dirnames`, so the root it was given is never one of them
    /// (`folder_duplicates.py:86-93`). A port that included the root would find pairs the CLI cannot, and
    /// the root against its own child is a nested pair that would be skipped anyway -- but against a
    /// *sibling* tree it would not, so this is a real difference and not a technicality.
    public var comparableIndices: [Int] {
        Array(nodes.indices.dropFirst())
    }

    /// The relative path of a file inside one of its ancestor directories.
    ///
    /// The CLI's `str(file_path.relative_to(folder))`, which is the key of its fingerprint dictionary.
    public func relativePath(ofFile fileIndex: Int, under directory: Int) -> String? {
        guard files.indices.contains(fileIndex), nodes.indices.contains(directory) else {
            return nil
        }
        return PathElision.relative(files[fileIndex].path, to: nodes[directory].path)
    }
}
