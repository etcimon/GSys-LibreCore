export function isHTMLSelectElement(
  input: Node,
): input is HTMLSelectElement {
  return (input instanceof HTMLSelectElement);
}
