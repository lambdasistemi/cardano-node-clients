// Copy text to the system clipboard via the async navigator.clipboard API.
// Returns a Promise<Unit>; failures propagate to Aff as rejection.
export const copyImpl = (text) => () =>
  navigator.clipboard.writeText(text);
