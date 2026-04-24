// Pretty-print a JSON string by parsing + re-stringifying with 2-space indent.
// If the input isn't valid JSON, return it unchanged.
export const prettyImpl = (text) => {
  try {
    return JSON.stringify(JSON.parse(text), null, 2);
  } catch (e) {
    return text;
  }
};
