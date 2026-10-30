import Foundation

/// List editing rules that match NotallyX (`ListManager`, `ListItemCollectionExtensions`).
/// Items are stored flat: a child belongs to the nearest parent above it.
public enum ListOps {
    /// Groups of (parent, children) in stored order.
    public static func groups(_ items: [ListItem]) -> [[ListItem]] {
        var out: [[ListItem]] = []
        for item in items {
            if item.isChild, !out.isEmpty { out[out.count - 1].append(item) } else {
                var parent = item
                parent.isChild = false
                out.append([parent])
            }
        }
        return out
    }

    /// Display and storage order: unchecked groups first, checked groups after (auto sort).
    /// `order` is rewritten to the position, like Android does when it saves.
    public static func normalized(_ items: [ListItem], autoSort: Bool) -> [ListItem] {
        var groups = groups(items).map(fixParentChecked)
        if autoSort {
            let unchecked = groups.filter { !$0[0].checked }
            let checked = groups.filter { $0[0].checked }
            groups = unchecked + checked
        }
        var out = groups.flatMap { $0 }
        for i in out.indices { out[i].order = i }
        return out
    }

    /// A parent with children is checked exactly when all children are checked.
    static func fixParentChecked(_ group: [ListItem]) -> [ListItem] {
        guard group.count > 1 else { return group }
        var g = group
        let allChecked = g.dropFirst().allSatisfy(\.checked)
        if allChecked != g[0].checked {
            g[0].checked = allChecked
            g[0].checkedTimestamp = allChecked ? (g.dropFirst().compactMap(\.checkedTimestamp).max() ?? Note.now()) : nil
        }
        return g
    }

    /// A parent also sets its children. `normalized` sets the parent of a child.
    public static func setChecked(_ items: inout [ListItem], at index: Int, _ checked: Bool, now: Int64 = Note.now()) {
        let stamp: Int64? = checked ? now : nil
        items[index].checked = checked
        items[index].checkedTimestamp = stamp
        if !items[index].isChild {
            var i = index + 1
            while i < items.count, items[i].isChild {
                items[i].checked = checked
                items[i].checkedTimestamp = stamp
                i += 1
            }
        }
    }

    public static func childIndices(_ items: [ListItem], ofParent p: Int) -> [Int] {
        var out: [Int] = []
        var i = p + 1
        while i < items.count, items[i].isChild { out.append(i); i += 1 }
        return out
    }

    /// Indent or outdent. The first item can never be a child.
    public static func setChild(_ items: inout [ListItem], at index: Int, _ isChild: Bool) {
        guard index > 0 || !isChild else { return }
        items[index].isChild = isChild
    }

    /// Insert a new empty item after `index` (or at the end), like `defaultNewItem`.
    @discardableResult
    public static func insert(_ items: inout [ListItem], after index: Int?) -> Int {
        let pos = index.map { $0 + 1 } ?? items.count
        let child = !items.isEmpty && ((pos < items.count && items[pos].isChild) || (pos > 0 && items[pos - 1].isChild))
        items.insert(ListItem(body: "", isChild: child), at: pos)
        return pos
    }

    /// Removes the item; children of a removed parent move to the parent above (or become parents).
    public static func remove(_ items: inout [ListItem], at index: Int) {
        let wasParent = !items[index].isChild
        items.remove(at: index)
        if wasParent, index == 0, !items.isEmpty { items[0].isChild = false }
    }

    public static func deleteChecked(_ items: inout [ListItem]) {
        items.removeAll(where: \.checked)
        if !items.isEmpty { items[0].isChild = false }
    }

    /// Moves a whole group (parent with children) or a single child.
    public static func move(_ items: inout [ListItem], from source: IndexSet, to destination: Int) {
        guard let first = source.first else { return }
        var moving = IndexSet(source)
        if !items[first].isChild {
            for c in childIndices(items, ofParent: first) { moving.insert(c) }
        }
        let block = moving.map { items[$0] }
        let before = moving.filter { $0 < destination }.count
        for i in moving.reversed() { items.remove(at: i) }
        let target = min(max(0, destination - before), items.count)
        items.insert(contentsOf: block, at: target)
        if !items.isEmpty { items[0].isChild = false }
    }
}
