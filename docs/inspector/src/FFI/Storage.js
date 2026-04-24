// Thin wrappers over localStorage so the project ID persists across
// page reloads. No cross-tab sync — if you want that, listen to the
// 'storage' event in a later iteration.

export const getItemImpl = (key) => () => {
  const v = window.localStorage.getItem(key);
  return v == null ? "" : v;
};

export const setItemImpl = (key) => (value) => () => {
  window.localStorage.setItem(key, value);
};
