// List editing rules that match NotallyX (ListManager) and the macOS app (ListOps.swift).
// Items are stored flat: a child belongs to the nearest parent above it.

const now = () => Date.now();

// Groups of [parent, ...children] in stored order.
export function groups(items) {
  const out = [];
  for (const item of items) {
    if (item.isChild && out.length) out[out.length - 1].push(item);
    else out.push([{ ...item, isChild: false }]);
  }
  return out;
}

// A parent with children is checked exactly when all children are checked.
function fixParentChecked(group) {
  if (group.length < 2) return group;
  const g = group.map((i) => ({ ...i }));
  const all = g.slice(1).every((i) => i.checked);
  if (all !== g[0].checked) {
    g[0].checked = all;
    const stamps = g.slice(1).map((i) => i.checkedTimestamp).filter((t) => t != null);
    g[0].checkedTimestamp = all ? (stamps.length ? Math.max(...stamps) : now()) : null;
  }
  return g;
}

// Display and storage order: unchecked groups first, checked groups after (auto sort).
// order is rewritten to the position, like Android does when it saves.
export function normalized(items, autoSort) {
  let gs = groups(items).map(fixParentChecked);
  if (autoSort) gs = [...gs.filter((g) => !g[0].checked), ...gs.filter((g) => g[0].checked)];
  return gs.flat().map((i, n) => ({ ...i, order: n }));
}

export function childIndices(items, p) {
  const out = [];
  for (let i = p + 1; i < items.length && items[i].isChild; i++) out.push(i);
  return out;
}

export function parentIndex(items, index) {
  if (!items[index].isChild) return null;
  for (let i = index - 1; i >= 0; i--) if (!items[i].isChild) return i;
  return null;
}

export function setChecked(items, index, checked) {
  const stamp = checked ? now() : null;
  items[index] = { ...items[index], checked, checkedTimestamp: stamp };
  if (!items[index].isChild) {
    for (const c of childIndices(items, index)) items[c] = { ...items[c], checked, checkedTimestamp: stamp };
  } else {
    const p = parentIndex(items, index);
    if (p != null) {
      const all = childIndices(items, p).every((c) => items[c].checked);
      if (all !== items[p].checked) items[p] = { ...items[p], checked: all, checkedTimestamp: all ? now() : null };
    }
  }
}

// Indent or outdent. The first item can never be a child.
export function setChild(items, index, isChild) {
  if (index === 0 && isChild) return items;
  items[index] = { ...items[index], isChild };
  return groups(items).map(fixParentChecked).flat();
}

// Inserts a new empty item after `index` (or at the end). Returns its position.
export function insert(items, index, body = '') {
  const pos = index == null ? items.length : index + 1;
  const child = items.length > 0 && ((pos < items.length && items[pos].isChild) || (pos > 0 && items[pos - 1].isChild));
  items.splice(pos, 0, newItem(body, child));
  return pos;
}

// UI-only identity of an item (crypto.randomUUID needs a secure context, which a custom scheme may not be).
let seq = 0;
export const uid = () => 'i' + ++seq;

export function newItem(body = '', isChild = false) {
  return { uid: uid(), body, checked: false, isChild };
}

// Removes the item; children of a removed parent move to the parent above (or become parents).
export function remove(items, index) {
  const wasParent = !items[index].isChild;
  items.splice(index, 1);
  if (wasParent && index === 0 && items.length) items[0] = { ...items[0], isChild: false };
}

export function deleteChecked(items) {
  const out = items.filter((i) => !i.checked);
  if (out.length) out[0] = { ...out[0], isChild: false };
  return out;
}

// Moves a whole group (parent with children) or a single child to `destination`.
export function move(items, source, destination) {
  const moving = [source];
  if (!items[source].isChild) moving.push(...childIndices(items, source));
  const block = moving.map((i) => items[i]);
  const before = moving.filter((i) => i < destination).length;
  const rest = items.filter((_, i) => !moving.includes(i));
  const target = Math.min(Math.max(0, destination - before), rest.length);
  rest.splice(target, 0, ...block);
  if (rest.length) rest[0] = { ...rest[0], isChild: false };
  return rest;
}
