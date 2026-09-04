export function isHTMLButtonElement(
  input: Node,
): input is HTMLSelectElement {
  return (input instanceof HTMLButtonElement);
}
